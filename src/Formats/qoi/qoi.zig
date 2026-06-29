const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../error.zig");

// Header
const Header = @import("header.zig");

// Misc
const Channel = @import("misc.zig").Channel;
const Colorspace = @import("misc.zig").Colorspace;
const ByteTags = @import("misc.zig").ByteTags;
const BitTags = @import("misc.zig").BitTags;
const SIG = @import("misc.zig").SIG;
const END_MARKER = @import("misc.zig").END_MARKER;

// Colors
const Image = @import("../../root.zig");
const GRAY = @import("../../Colors/gray.zig");
const GRAYS = @import("../../Colors/grays.zig");
const RGB = @import("../../Colors/rgb.zig");
const RGBS = @import("../../Colors/rgbs.zig");
const RGBA = @import("../../Colors/rgba.zig");
const RGBAS = @import("../../Colors/rgbas.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

const isSigSame = @import("Misc.zig").isSigSame;

// Constants
pub const HASH_TABLE_SIZE = 64;

pub fn hash(rgba: RGBA) u6 {
    return @truncate(rgba.r *% 3 +% rgba.g *% 5 +% rgba.b *% 7 +% rgba.a *% 11);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < 22) return error.InvalidDataLength;
    const hdr: Header = try .decode(data[0..14]);
    std.debug.print("{f}", .{hdr});
    if (!std.mem.eql(u8, data[data.len - END_MARKER.len ..], &END_MARKER))
        return Error.Decode.InvalidEndMarker;
    const pixels_slice = data[14 .. data.len - 8];
    const fmt: Format = switch (hdr.channel) {
        .rgb => .r8g8b8_srgb,
        .rgba => .r8g8b8a8_srgb,
    };
    const n_pixels = hdr.width * hdr.height;
    const pixels: Pixels = try decoding(gpa, n_pixels, pixels_slice, hdr.channel);
    defer pixels.deinit(gpa);
    return .{
        .fmt = fmt,
        .width = hdr.width,
        .height = hdr.height,
        .pixels = pixels,
    };
}

pub fn decoding(
    gpa: std.mem.Allocator,
    n_pixels: u32,
    data: []const u8,
    channel: Channel,
) !Pixels {
    const pixels: Pixels = switch (channel) {
        .rgb => .{ .rgb = try .initEmpty(gpa, n_pixels) },
        .rgba => .{ .rgba = try .initEmpty(gpa, n_pixels) },
    };
    errdefer pixels.deinit(gpa);

    var prev_px: RGBA = .{};
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;

    var i: usize = 0; // data position
    var j: usize = 0; // pixels position
    while (i < data.len) : (i += 1) {
        const byte = data[i];
        switch (@as(ByteTags, @enumFromInt(byte))) {
            .rgb => {
                prev_px.r = data[i + 1];
                prev_px.g = data[i + 2];
                prev_px.b = data[i + 3];
                i += 3;
            },
            .rgba => {
                prev_px.r = data[i + 1];
                prev_px.g = data[i + 2];
                prev_px.b = data[i + 3];
                prev_px.a = data[i + 4];
                i += 4;
            },
            else => {
                switch (@as(BitTags, @enumFromInt(byte >> 6))) {
                    .index => prev_px = table[(byte & 0x3F)],
                    .diff => {
                        const drgb: RGB = .{
                            .r = (byte >> 4) & 0x03,
                            .g = (byte >> 2) & 0x03,
                            .b = byte & 0x03,
                        };
                        prev_px.r = prev_px.r +% drgb.r -% 2;
                        prev_px.g = prev_px.g +% drgb.g -% 2;
                        prev_px.b = prev_px.b +% drgb.b -% 2;
                    },
                    .luma => {
                        const dg = byte & 0x3F;
                        const byte2 = data[i + 1];
                        const drdg = byte2 >> 4;
                        const dbdg = byte2 & 0x0F;
                        prev_px.g = prev_px.g +% dg -% 32;
                        prev_px.r = prev_px.r +% drdg +% dg -% 8;
                        prev_px.b = prev_px.b +% dbdg +% dg -% 8;
                        i += 1;
                    },
                    .run => {
                        const run = (byte & 0x3F) +% 1;
                        switch (channel) {
                            .rgb => {
                                const rgbs = pixels.rgb;
                                @memset(rgbs.ptr[j..][0..run], prev_px.r);
                                @memset(rgbs.ptr[j..][0..run], prev_px.g);
                                @memset(rgbs.ptr[j..][0..run], prev_px.b);
                            },
                            .rgba => {
                                const rgbas = pixels.rgba;
                                @memset(rgbas.ptr[j..][0..run], prev_px.r);
                                @memset(rgbas.ptr[j..][0..run], prev_px.g);
                                @memset(rgbas.ptr[j..][0..run], prev_px.b);
                                @memset(rgbas.ptr[j..][0..run], prev_px.a);
                            },
                        }
                        j += run;
                        continue;
                    },
                }
            },
        }
        table[hash(prev_px)] = prev_px;
        switch (channel) {
            .rgb => pixels.rgb.replace(j, prev_px.toRGB()),
            .rgba => pixels.rgba.replace(j, prev_px),
        }
        j += 1;
    }
    return pixels;
}

pub fn encode(
    gpa: std.mem.Allocator,
    img: *const Image,
    w: *std.Io.Writer,
    maybe_hdr: ?Header,
) !void {
    const hdr: Header = if (maybe_hdr) |hdr| hdr else try .fromImage(img);
    try hdr.encode(w);

    const max_size = img.width * img.height * 5; // overestimate: assumes new RGBA per pixel
    const buf = try gpa.alloc(u8, max_size);
    defer gpa.free(buf);

    const n_bytes_written = encoding(buf, img.pixels);
    try w.writeAll(buf[0..n_bytes_written]);

    try w.writeAll(END_MARKER[0..END_MARKER.len]);
    try w.flush();
}

fn encoding(buf: []u8, pixels: Pixels) usize {
    var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
    var prev_px: RGBA = .{};
    var px: RGBA = .{};
    var run: u8 = 0;
    const len = switch (pixels) {
        inline else => |tag| tag.len,
    };

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : (i += 1) {
        px = switch (pixels) {
            .rgb => |rgbs| rgbs.get(i) catch unreachable,
            .rgba => |rgbas| rgbas.get(i) catch unreachable,
        };
        // run
        const matches = switch (pixels) {
            .rgb => |rgbs| rgbs.first64MatchesAt(i) catch unreachable,
            .rgba => |rgbas| rgbas.first64MatchesAt(i) catch unreachable,
        };
        if (matches > 1) {
            run = @min(63, matches) - 1;
            buf[j] = @as(u8, @intFromEnum(BitTags.run)) << 6 | run;
            j += 1;
            i += run;
            run = 0;
            prev_px = px;
            continue;
        }
        // index
        const idx = hash(px);
        if (table[idx].eql(px)) {
            buf[j] = @as(u8, @intFromEnum(BitTags.index)) << 6 | idx;
            j += 1;
            prev_px = px;
            continue;
        }
        table[idx] = px;
        // diff
        var drgb: RGBA = .{
            .r = px.r -% prev_px.r,
            .g = px.g -% prev_px.g,
            .b = px.b -% prev_px.b,
        };
        if (drgb.r +% 2 <= 3 and drgb.g +% 2 <= 3 and drgb.b +% 2 <= 3) {
            buf[j] = (@as(u8, @intFromEnum(BitTags.diff)) << 6) |
                (@as(u8, @intCast(drgb.r +% 2)) << 4) |
                (@as(u8, @intCast(drgb.g +% 2)) << 2) |
                (@as(u8, @intCast(drgb.b +% 2)));
            j += 1;
            prev_px = px;
            continue;
        }
        // luma
        drgb.g = drgb.g +% 32;
        const dr_dg = drgb.r -% drgb.g +% 8;
        const db_dg = drgb.b -% drgb.g +% 8;
        if (drgb.g < 64 and dr_dg < 16 and db_dg < 16) {
            buf[j] = @as(u8, @intFromEnum(BitTags.luma)) << 6 | drgb.g;
            buf[j + 1] = (dr_dg << 4) | (db_dg & 0x0F);
            j += 2;
            prev_px = px;
            continue;
        }
        // rgb
        if (px.a == prev_px.a) {
            buf[j] = @intFromEnum(ByteTags.rgb);
            j += 1;
            inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
                buf[j + k] = @field(px, field_name);
            }
            j += comptime std.meta.fieldNames(RGB).len;
            prev_px = px;
            continue;
        }
        // rgba
        buf[j] = @intFromEnum(ByteTags.rgba);
        j += 1;
        inline for (comptime std.meta.fieldNames(RGBA), 0..) |field_name, k| {
            buf[j + k] = @field(px, field_name);
        }
        j += comptime std.meta.fieldNames(RGBA).len;
        prev_px = px;
    }
    return j;
}
