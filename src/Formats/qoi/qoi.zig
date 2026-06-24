const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("error.zig");

// Header
const Header = @import("header.zig");

// Misc
const Channel = @import("misc.zig").Channel;
const Colorspace = @import("misc.zig").Colorspace;
const ByteTags = @import("misc.zig").ByteTags;
const BitTags = @import("misc.zig").BitTags;
const hashRGB = @import("misc.zig").hashRGB;
const hashRGBA = @import("misc.zig").hashRGBA;
const SIG = @import("misc.zig").SIG;
const END_MARKER = @import("misc.zig").END_MARKER;

// Colors
const Image = @import("../root.zig");
const GRAY = @import("../Colors/gray.zig");
const GRAYS = @import("../Colors/grays.zig");
const RGB = @import("../Colors/rgb.zig");
const RGBS = @import("../Colors/rgbs.zig");
const RGBA = @import("../Colors/rgba.zig");
const RGBAS = @import("../Colors/rgbas.zig");
const Pixels = @import("../Colors/Pixels.zig");

const isSigSame = @import("Misc.zig").isSigSame;

// Constants
pub const HASH_TABLE_SIZE = 64;

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void {
    const hdr: Header = try .decode(data);
    std.debug.print("{f}", .{hdr});
    // check end bytes
    std.debug.assert(std.mem.eql(u8, data[data.len - 8 ..], [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }));

    const pixels_slice = data[14 .. data.len - 8];
    if (!std.mem.eql(u8, pixels_slice[pixels_slice.len - END_MARKER.len ..], &END_MARKER))
        return Error.Decode.InvalidEndMarker;
    const n_pixels = hdr.width * hdr.height;
    const pixels: Pixels = switch (hdr.channels) {
        .rgb => .{ .rgb = try .initCapacity(gpa, n_pixels) },
        .rgba => .{ .rgba = try .initCapacity(gpa, n_pixels) },
    };
    defer pixels.deinit(gpa);

    var i: usize = 0; // input position
    var j: usize = 0; // output position
    var prev_pixel: RGBA = .{ .r = 0, .b = 0, .g = 0, .a = 0xFF };
    var indices = [_]RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0xFF }} ** HASH_TABLE_SIZE;
    while (i < pixels_slice.len) : (i += 1) {
        const byte = pixels_slice[i];
        switch (byte) {
            0xFE => { // RGB
                if (i + 3 > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                prev_pixel = .{
                    .r = pixels_slice[i + 1],
                    .g = pixels_slice[i + 2],
                    .b = pixels_slice[i + 3],
                };
                i += 3;
            },
            0xFF => { // RGBA
                if (i + 4 > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                prev_pixel = .{
                    .r = pixels_slice[i + 1],
                    .g = pixels_slice[i + 2],
                    .b = pixels_slice[i + 3],
                    .a = pixels_slice[i + 4],
                };
                i += 4;
            },
            else => {
                const byte2 = pixels_slice[i];
                const bits: BitTags = @enumFromInt(byte2 >> 6);
                switch (bits) {
                    .index => {
                        const idx: u6 = @truncate(byte2);
                        prev_pixel = indices[idx];
                    },
                    .diff => { // TODO FIXME
                        std.debug.print("Diff\n", .{});
                        const dr = (byte2 >> 4) & 0x03;
                        const dg = (byte2 >> 2) & 0x03;
                        const db = byte2 & 0x03;
                        const dr2 = @as(i8, @intCast((byte2 >> 4) & 0x03)) - 2;
                        const dg2 = @as(i8, @intCast((byte2 >> 2) & 0x03)) - 2;
                        const db2 = @as(i8, @intCast((byte2) & 0x03)) - 2;
                        std.debug.print("Dpixel 1: {} {} {}\n", .{ dr, dg, db });
                        std.debug.print("Dpixel 2: {} {} {}\n", .{ dr2, dg2, db2 });
                        const pr = prev_pixel.r +% @as(u8, @bitCast(dr2));
                        const pg = prev_pixel.g +% @as(u8, @bitCast(dg2));
                        const pb = prev_pixel.b +% @as(u8, @bitCast(db2));
                        prev_pixel.r = prev_pixel.r +% dr -% 2;
                        prev_pixel.g = prev_pixel.g +% dg -% 2;
                        prev_pixel.b = prev_pixel.b +% db -% 2;
                        std.debug.print("Prev Pixel 1: {} {} {}\n", .{ prev_pixel.r, prev_pixel.g, prev_pixel.b });
                        std.debug.print("Prev Pixel 2: {} {} {}\n", .{ pr, pg, pb });
                    },
                    .luma => { // TODO FIXME
                        std.debug.print("Luma\n", .{});
                        i += 1;
                        if (i > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                        const byte3 = pixels_slice[i];
                        const dg = byte3 & 0x3F; // -32:31
                        const drdg = byte3 >> 4; // -8:7
                        const dbdg = byte3 & 0x3F; // -8:7
                        const dg2 = @as(i8, @intCast((byte3 & 0x3F))) - 32;
                        const drdg2 = @as(i8, @intCast((byte3 >> 4) & 0x0F)) - 8;
                        const dbdg2 = @as(i8, @intCast(byte3 & 0x0F)) - 8;
                        std.debug.print("Dpixel 1: {} {} {}\n", .{ dg, drdg, dbdg });
                        std.debug.print("Dpixel 1: {} {} {}\n", .{ dg2, drdg2, dbdg2 });
                        const pr = prev_pixel.g +% @as(u8, @bitCast(dg2));
                        const pg = prev_pixel.r +% @as(u8, @bitCast(dg2 +% drdg2));
                        const pb = prev_pixel.b +% @as(u8, @bitCast(dg2 +% dbdg2));
                        prev_pixel.g = prev_pixel.g +% dg -% 32;
                        prev_pixel.r = prev_pixel.r +% drdg +% dg -% 8;
                        prev_pixel.b = prev_pixel.b +% dbdg +% dg -% 8;
                        std.debug.print("Prev Pixel 1: {} {} {}\n", .{ prev_pixel.r, prev_pixel.g, prev_pixel.b });
                        std.debug.print("Prev Pixel 2: {} {} {}\n", .{ pr, pg, pb });
                    },
                    .run => {
                        const run: usize = (byte & 0x3F) + 1;
                        if (j + run > n_pixels) return Error.Decode.DataOutOfBounds;
                        switch (pixels) {
                            .rgb => |rgb| {
                                const slice = rgb.slice();
                                const r = slice.ptrs[0];
                                const g = slice.ptrs[1];
                                const b = slice.ptrs[2];
                                @memset(r[j..][0..run], prev_pixel.r);
                                @memset(g[j..][0..run], prev_pixel.g);
                                @memset(b[j..][0..run], prev_pixel.b);
                            },
                            .rgba => |rgba| {
                                const slice = rgba.slice();
                                const r = slice.ptrs[0];
                                const g = slice.ptrs[1];
                                const b = slice.ptrs[2];
                                const a = slice.ptrs[3];
                                @memset(r[j..][0..run], prev_pixel.r);
                                @memset(g[j..][0..run], prev_pixel.g);
                                @memset(b[j..][0..run], prev_pixel.b);
                                @memset(a[j..][0..run], prev_pixel.a);
                            },
                            else => unreachable,
                        }
                        j += run;
                        continue;
                    },
                }
            },
        }

        indices[hash(prev_pixel)] = prev_pixel;

        if (j + 1 > n_pixels) return Error.Decode.DataOutOfBounds;
        j += 1;

        switch (pixels) {
            .rgb => |rgb| rgb.appendAssumeCapacity(.{
                .r = prev_pixel.r,
                .g = prev_pixel.g,
                .b = prev_pixel.b,
            }),
            .rgba => |rgba| rgba.appendAssumeCapacity(prev_pixel),
            else => unreachable,
        }
    }

    // verify end marker
    if (i != pixels_slice.len - 8) return Error.Decode.InvalidEndMarker;
}

pub fn encode(
    gpa: std.mem.Allocator,
    img: *const Image,
    w: *std.Io.Writer,
    maybe_hdr: ?Header,
) !void {
    _ = gpa;
    _ = img;
    _ = w;
    _ = maybe_hdr;
    // const n_pixels = switch (img.pixels) {
    //     inline else => |colors| colors.slice.len,
    // };
    // const max_size = @sizeOf(Header) + n_pixels * 5 + END_MARKER.len;
    // var buf = try gpa.alloc(u8, max_size);
    // defer gpa.free(buf);
    //
    // var write_buf: [1024]u8 = undefined;
    // var w_idx: usize = 0;
    //
    // const hdr: Header = if (maybe_hdr) |hdr| hdr else try .fromImage(img);
    // try hdr.encode(w);
    //
    // switch (img.pixels) {
    //     .rgb => |rgbs| _ = rgbs,
    //     .rgba => |rgbas| _ = rgbas,
    //     else => unreachable,
    // }
}

fn encodeData(
    comptime T: Channel,
    buf: []u8,
    data: switch (T) {
        .rgb => []const RGB,
        .rgba => []const RGBA,
    },
) !void {
    const n_pixels = data.len;
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
    var prev: RGBA = .{ .r = 0, .g = 0, .b = 0 };
    var run: usize = 0;

    var i: usize = 0;
    var b: usize = 0; // buffer index
    while (i < data.len) : (i += 1) {
        const px: RGBA = .{
            .r = data[i],
            .g = data[i + 1],
            .b = data[i + 2],
            .a = data[i + 3],
        };

        // check run
        if (px.eql(prev)) {
            run += 1;
            if (run == 62 or i == n_pixels - 1) {
                buf[b] = @intFromEnum(BitTags.run) << 6 | @as(u8, @intCast(run - 1));
                b += 1;
                run = 0;
            }
            prev = px;
            continue;
        }

        // flush run
        if (run > 0) {
            buf[b] = @as(u8, @intFromEnum(BitTags.run) << 6) | @as(u8, @intCast(run - 1));
            b += 1;
            run = 0;
        }

        // index
        const idx = hash(px);
        if (table[idx].eql(px)) {
            buf[b] = @as(u8, @intFromEnum(BitTags.index) << 6) | @as(u8, idx);
            b += 1;
            table[idx] = px;
            prev = px;
            continue;
        }
        table[idx] = px;

        if (px.a == prev.a) {
            const dr = @as(i16, px.r) - prev.r;
            const dg = @as(i16, px.g) - prev.g;
            const db = @as(i16, px.b) - prev.b;

            const dr_dg = dr - dg;
            const db_dg = db - dg;

            if (dr >= -2 and dr <= 1 and //
                dg >= -2 and dg <= 1 and //
                db >= -2 and db <= 1)
            {
                // diff
                buf[b] = @as(u8, @intFromEnum(BitTags.diff) << 6) |
                    @as(u8, @intCast(dr + 2)) << 4 |
                    @as(u8, @intCast(dg + 2)) << 2 |
                    @as(u8, @intCast(db + 2));
                b += 1;
            } else if (dg >= -32 and dg <= 31 and
                dr_dg >= -8 and dr_dg <= 7 and
                db_dg >= -8 and db_dg <= 7)
            {
                // luma
                buf[b] = (@intFromEnum(BitTags.luma) << 6) | (@as(u8, @intCast(dg)) + 32);
                buf[b + 1] = (@as(u8, @intCast(dr_dg + 8)) << 4) | (@as(u8, @intCast(db_dg)) + 8);
            } else {
                // rgb
                buf[b] = @intFromEnum(ByteTags.rgb);
                buf[b + 1] = px.r;
                buf[b + 2] = px.g;
                buf[b + 3] = px.b;
                b += 4;
            }
        } else {
            // RGBA
            buf[b] = @intFromEnum(ByteTags.rgba);
            buf[b + 1] = px.r;
            buf[b + 2] = px.g;
            buf[b + 3] = px.b;
            buf[b + 4] = px.a;
        }
        prev = px;
    }
    // end marker
    @memcpy(buf[b .. b + END_MARKER.len], &END_MARKER);
    b += END_MARKER.len;
    return buf;

    // shrink memory to used values
    // const result = try gpa.realloc(buf, b);
    // return result;
}

fn encodeDataSIMD(
    comptime T: Channel,
    buf: []u8,
    data: switch (T) {
        .rgb => []const RGB,
        .rgba => []const RGBA,
    },
) !void {
    var table = [_]RGBA{.{}} ** 64;
    var prev: RGBA = .{};
    var run: usize = 0;

    const n_pixels = data.len;
    var i: usize = 0; // index into data
    var j: usize = 0; // index into buffer
    while (true) {
        const n_matches = if (i + 64 <= n_pixels) //
            firstNMatchesSIMD(T, data[i], @ptrCast(data[i..][0..64]))
        else //
            firstNMatches(T, data[i], data[i..]);
        if (n_matches > 0) {
            buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | run;
        }
        const px = data[i];
        // check run
        if (px.eql(prev)) {
            run += 1;
            if (run == 62 or i == n_pixels - 1) {
                buf[j] = @intFromEnum(BitTags.run) << 6 | @as(u8, @intCast(run - 1));
                j += 1;
                run = 0;
            }
            prev = px;
            continue;
        }

        // flush run
        if (run > 0) {
            buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | @as(u8, @intCast(run - 1));
            j += 1;
            run = 0;
        }

        i += 1;
    }
}

fn firstNMatches(
    comptime T: Channel,
    current: switch (T) {
        .rgb => RGB,
        .rgba => RGBA,
    },
    slice: switch (T) {
        .rgb => []RGB,
        .rgba => []RGBA,
    },
) usize {
    for (slice, 0..) |s, i| {
        if (!current.eql(s)) return i;
    } else return slice.len;
}

fn firstNMatchesSIMD(
    comptime T: Channel,
    current: switch (T) {
        .rgb => RGB,
        .rgba => RGBA,
    },
    array: switch (T) {
        .rgb => *[64]RGB,
        .rgba => *[64]RGBA,
    },
) usize {
    const V = @Vector(64, u32);
    const self: V = @splat(@as(u32, @bitCast(current)));
    const other: V = @bitCast(array);
    return @min(@ctz(@as(usize, @bitCast(self != other))), 62) - 1;
}

test "First N Matches" {
    const rgb: RGB = .{ .r = 0, .g = 0, .b = 0 };
    const rgbs = [_]RGB{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 1, .g = 1, .b = 1 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 1, .g = 1, .b = 1 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 1, .g = 1, .b = 1 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 1, .g = 1, .b = 1 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 1, .g = 1, .b = 1 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 1, .g = 1, .b = 1 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
        .{ .r = 1, .g = 1, .b = 1 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 1, .g = 1, .b = 1 },
    };
    const n_matches1 = firstNMatches(.rgb, rgb, &rgbs);
    try std.testing.expectEqual(n_matches1, 6);

    const rgba: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    const rgbas = [_]RGBA{
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },

        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 0, .g = 0, .b = 0 },
    };
    const n_matches2 = firstNMatches(.rgba, rgba, &rgbas);
    try std.testing.expectEqual(n_matches2, 64);
}
