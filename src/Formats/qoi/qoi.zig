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
const hashRGB = @import("misc.zig").hashRGB;
const hashRGBA = @import("misc.zig").hashRGBA;
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
const Pixels = @import("../../Colors/Pixels.zig");

const isSigSame = @import("Misc.zig").isSigSame;

// Constants
pub const HASH_TABLE_SIZE = 64;

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void {
    const hdr: Header = try .decode(data);
    const pixels_slice = data[14 .. data.len - 8];
    if (!std.mem.eql(u8, pixels_slice[pixels_slice.len - END_MARKER.len ..], &END_MARKER))
        return Error.Decode.InvalidEndMarker;

    const n_pixels = hdr.width * hdr.height;
    const pixels: Pixels = switch (hdr.channels) {
        .rgb => .{ .rgb = try .initEmpty(gpa, n_pixels) },
        .rgba => .{ .rgba = try .initEmpty(gpa, n_pixels) },
    };
    defer pixels.deinit(gpa);

    var i: usize = 0; // data position
    var j: usize = 0; // pixels position
    var prev_pixel: RGBA = .{ .r = 0, .b = 0, .g = 0, .a = 0xFF };
    var table = [_]RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0xFF }} ** HASH_TABLE_SIZE;
    while (i < pixels_slice.len) : (i += 1) {
        const byte = pixels_slice[i];
        switch (@as(ByteTags, @enumFromInt(byte))) {
            .rgb => {
                if (i + @sizeOf(RGB) > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
                    @field(prev_pixel, field_name) = pixels_slice[i + k + 1];
                }
                i += @sizeOf(RGB);
            },
            .rgba => {
                if (i + @sizeOf(RGBA) > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                inline for (comptime std.meta.fieldNamse(RGBA), 0..) |field_name, k| {
                    @field(prev_pixel, field_name) = pixels_slice[i + k + 1];
                }
                i += @sizeOf(RGBA);
            },
            else => {
                switch (@as(BitTags, @enumFromInt(byte >> 6))) {
                    .index => {
                        prev_pixel = table[@as(u6, @truncate(byte))];
                    },
                    .diff => {
                        const dr = (byte >> 4) & 0x03;
                        const dg = (byte >> 2) & 0x03;
                        const db = byte & 0x03;
                        prev_pixel.r = prev_pixel.r +% dr -% 2;
                        prev_pixel.g = prev_pixel.g +% dg -% 2;
                        prev_pixel.b = prev_pixel.b +% db -% 2;
                    },
                    .luma => {
                        i += 1;
                        if (i > pixels_slice.len) return Error.Decode.UnexpectedEndOfData;
                        const byte2 = pixels_slice[i];

                        const dg = byte & 0x3F;
                        const drdg = byte2 >> 4;
                        const dbdg = byte2 & 0x3F;

                        prev_pixel.g = prev_pixel.g +% dg -% 32;
                        prev_pixel.r = prev_pixel.r +% drdg +% dg -% 8;
                        prev_pixel.b = prev_pixel.b +% dbdg +% dg -% 8;
                    },
                    .run => {
                        const run: usize = (byte & 0x3F) +% 1;
                        if (j + run > n_pixels) return Error.Decode.DataOutOfBounds;
                        switch (pixels) {
                            .rgb => |rgbs| {
                                inline for (comptime std.meta.fieldNames(RGB)) |field_name| {
                                    @memset(rgbs.ptr[j..][0..run], @field(prev_pixel, field_name));
                                }
                            },
                            .rgba => |rgbas| {
                                inline for (comptime std.meta.fieldNames(RGBA)) |field_name| {
                                    @memset(rgbas.ptr[j..][0..run], @field(prev_pixel, field_name));
                                }
                            },
                            else => unreachable,
                        }
                        j += run;
                        continue;
                    },
                }
            },
        }

        table[hashRGBA(prev_pixel)] = prev_pixel;

        if (j + 1 > n_pixels) return Error.Decode.DataOutOfBounds;
        j += 1;

        switch (pixels) {
            .rgb => |rgbs| try rgbs.replace(i, prev_pixel.toRGB()),
            .rgba => |rgbas| try rgbas.replace(i, prev_pixel),
            else => unreachable,
        }
    }

    // verify end marker
    if (i != pixels_slice.len - 8) return Error.Decode.InvalidEndMarker;
}

// pub fn encode(
//     gpa: std.mem.Allocator,
//     img: *const Image,
//     w: *std.Io.Writer,
//     maybe_hdr: ?Header,
// ) !void {
//     const n_pixels = switch (img.pixels) {
//         inline else => |colors| colors.slice.len,
//     };
//     const max_size = @sizeOf(Header) + n_pixels * 5 + END_MARKER.len;
//     var buf = try gpa.alloc(u8, max_size);
//     defer gpa.free(buf);
//
//     const hdr: Header = if (maybe_hdr) |hdr| hdr else try .fromImage(img);
//     try hdr.encode(w);
//
//     switch (img.pixels) {
//         .rgb => |rgbs| encodeDataSIMD(.rgb, &buf, rgbs, hashRGB),
//         .rgba => |rgbas| encodeDataSIMD(.rgba, &buf, rgbas, hashRGBA),
//         else => unreachable,
//     }
// }
//
// fn encodeData(
//     comptime T: Channel,
//     buf: []u8,
//     data: switch (T) {
//         .rgb => []const RGB,
//         .rgba => []const RGBA,
//     },
//     hash: switch (T) {
//         .rgb => *const fn (RGB) u6,
//         .rgba => *const fn (RGBA) u6,
//     },
// ) !void {
//     const n_pixels = data.len;
//     var table = [_]RGBA{.{}} ** HASH_TABLE_SIZE;
//     var prev: RGBA = .{ .r = 0, .g = 0, .b = 0 };
//     var run: usize = 0;
//
//     var i: usize = 0;
//     var b: usize = 0; // buffer index
//     while (i < data.len) : (i += 1) {
//         const px: RGBA = .{
//             .r = data[i],
//             .g = data[i + 1],
//             .b = data[i + 2],
//             .a = data[i + 3],
//         };
//
//         // check run
//         if (px.eql(prev)) {
//             run += 1;
//             if (run == 62 or i == n_pixels - 1) {
//                 buf[b] = @intFromEnum(BitTags.run) << 6 | @as(u8, @intCast(run - 1));
//                 b += 1;
//                 run = 0;
//             }
//             prev = px;
//             continue;
//         }
//
//         // flush run
//         if (run > 0) {
//             buf[b] = @as(u8, @intFromEnum(BitTags.run) << 6) | @as(u8, @intCast(run - 1));
//             b += 1;
//             run = 0;
//         }
//
//         // index
//         const idx = hash(px);
//         if (table[idx].eql(px)) {
//             buf[b] = @as(u8, @intFromEnum(BitTags.index) << 6) | @as(u8, idx);
//             b += 1;
//             table[idx] = px;
//             prev = px;
//             continue;
//         }
//         table[idx] = px;
//
//         if (px.a == prev.a) {
//             const dr = @as(i16, px.r) - prev.r;
//             const dg = @as(i16, px.g) - prev.g;
//             const db = @as(i16, px.b) - prev.b;
//
//             const dr_dg = dr - dg;
//             const db_dg = db - dg;
//
//             if (dr >= -2 and dr <= 1 and //
//                 dg >= -2 and dg <= 1 and //
//                 db >= -2 and db <= 1)
//             {
//                 // diff
//                 buf[b] = @as(u8, @intFromEnum(BitTags.diff) << 6) |
//                     @as(u8, @intCast(dr + 2)) << 4 |
//                     @as(u8, @intCast(dg + 2)) << 2 |
//                     @as(u8, @intCast(db + 2));
//                 b += 1;
//             } else if (dg >= -32 and dg <= 31 and
//                 dr_dg >= -8 and dr_dg <= 7 and
//                 db_dg >= -8 and db_dg <= 7)
//             {
//                 // luma
//                 buf[b] = (@intFromEnum(BitTags.luma) << 6) | (@as(u8, @intCast(dg)) + 32);
//                 buf[b + 1] = (@as(u8, @intCast(dr_dg + 8)) << 4) | (@as(u8, @intCast(db_dg)) + 8);
//             } else {
//                 // rgb
//                 buf[b] = @intFromEnum(ByteTags.rgb);
//                 buf[b + 1] = px.r;
//                 buf[b + 2] = px.g;
//                 buf[b + 3] = px.b;
//                 b += 4;
//             }
//         } else {
//             // RGBA
//             buf[b] = @intFromEnum(ByteTags.rgba);
//             buf[b + 1] = px.r;
//             buf[b + 2] = px.g;
//             buf[b + 3] = px.b;
//             buf[b + 4] = px.a;
//         }
//         prev = px;
//     }
//     // end marker
//     @memcpy(buf[b .. b + END_MARKER.len], &END_MARKER);
//     b += END_MARKER.len;
//     return buf;
//
//     // shrink memory to used values
//     // const result = try gpa.realloc(buf, b);
//     // return result;
// }
//
// fn encodeDataSIMD(
//     comptime T: Channel,
//     buf: []u8,
//     data: switch (T) {
//         .rgb => []const RGB,
//         .rgba => []const RGBA,
//     },
//     hash: switch (T) {
//         .rgb => *const fn (RGB) u6,
//         .rgba => *const fn (RGBA) u6,
//     },
// ) !void {
//     var table = [_]RGBA{.{}} ** 64;
//     var prev: switch (T) {
//         .rgb => RGB,
//         .rgba => RGBA,
//     } = .{};
//     var run: usize = 0;
//
//     const n_pixels = data.len;
//     var i: usize = 0; // index into data
//     var j: usize = 0; // index into buffer
//     while (true) {
//         const n_matches = if (i + 64 <= n_pixels) //
//             firstNMatchesSIMD(T, data[i], @ptrCast(data[i..][0..64]))
//         else //
//             firstNMatches(T, data[i], data[i..]);
//         if (n_matches > 0) {
//             buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | run;
//         }
//         const px = data[i];
//         // check run
//         if (px.eql(prev)) {
//             run += 1;
//             if (run == 62 or i == n_pixels - 1) {
//                 buf[j] = @intFromEnum(BitTags.run) << 6 | @as(u8, @intCast(run - 1));
//                 j += 1;
//                 run = 0;
//             }
//             prev = px;
//             continue;
//         }
//
//         // flush run
//         if (run > 0) {
//             buf[j] = @as(u8, @intFromEnum(BitTags.run) << 6) | @as(u8, @intCast(run - 1));
//             j += 1;
//             run = 0;
//         }
//
//         // index
//         const idx = hash(px);
//         if (table[idx].eql(px)) {
//             buf[j] = @as(u8, @intFromEnum(BitTags.index) << 6) | @as(u8, idx);
//             j += 1;
//             table[idx] = px;
//             prev = px;
//             continue;
//         }
//         table[idx] = px;
//
//         switch (T) {
//             .rgb => {
//                 const dr = @as(i8, px.r) - prev.r;
//                 const dg = @as(i8, px.g) - prev.g;
//                 const db = @as(i8, px.b) - prev.b;
//                 const dr_dg = dr - dg;
//                 const db_dg = db - dg;
//                 if (dr >= -2 and dr <= 1 and //
//                     dg >= -2 and dg <= 1 and //
//                     db >= -2 and db <= 1)
//                 {
//                     // diff
//                     buf[j] = calcDiff(.{ .r = dr, .g = dg, .b = db });
//                 }
//             },
//             .rgba => {
//                 if (px.a == prev.a) {
//                     const drgb: RGB = .{
//                         .r = px.r -% prev.r,
//                         .g = px.g -% prev.g,
//                         .b = px.b -% prev.b,
//                     };
//                     const drgb_dg: RGB = .{
//                         .r = drgb.r - drgb.g,
//                         .g = drgb.g,
//                         .b = drgb.b - drgb.g,
//                     };
//                     if (drgb.r >= -2 and drgb <= 1 and //
//                         dg >= -2 and dg <= 1 and //
//                         db >= -2 and db <= 1)
//                     {
//                         // diff
//                         buf[j] = calcDiff(.{ .r = @intCast(dr), .g = @intCast(dg), .b = @intCast(db) });
//                         j += 1;
//                     } else if (dg >= -32 and dg <= 31 and
//                         dr_dg >= -8 and dr_dg <= 7 and
//                         db_dg >= -8 and db_dg <= 7)
//                     {
//                         // luma
//                         buf[j] = (@intFromEnum(BitTags.luma) << 6) | (@as(u8, @intCast(dg)) + 32);
//                         buf[j + 1] = (@as(u8, @intCast(dr_dg + 8)) << 4) | (@as(u8, @intCast(db_dg)) + 8);
//                     } else {
//                         // rgb
//                         buf[j] = @intFromEnum(ByteTags.rgb);
//                         buf[j + 1] = px.r;
//                         buf[j + 2] = px.g;
//                         buf[j + 3] = px.b;
//                         j += 4;
//                     }
//                 } else {
//                     // RGBA
//                     buf[j] = @intFromEnum(ByteTags.rgba);
//                     buf[j + 1] = px.r;
//                     buf[j + 2] = px.g;
//                     buf[j + 3] = px.b;
//                     buf[j + 4] = px.a;
//                     j += 5;
//                 }
//                 prev = px;
//             },
//         }
//     }
// }
//
// fn calcDiff(rgb: RGB) RGB {
//     return @as(u8, @intFromEnum(BitTags.diff) << 6) |
//         (rgb.r + 2) << 4 |
//         (rgb.g + 2) << 2 |
//         (rgb.b + 2);
// }
//
// fn calcLuma() void {}

fn countStartingMatches(
    comptime T: Channel,
    needle: switch (T) {
        .rgb => RGB,
        .rgba => RGBA,
    },
    haystack: switch (T) {
        .rgb => RGB,
        .rgba => RGBA,
    },
) usize {
    for (haystack, 0..) |s, i| {
        if (!needle.eql(s)) return i;
    } else return haystack.len;
}

fn countStartingMatchesSIMD(
    comptime T: Channel,
    needle: switch (T) {
        .rgb => RGB,
        .rgba => RGBA,
    },
    haystack: switch (T) {
        .rgb => RGB,
        .rgba => RGBA,
    },
) u64 {
    const V = @Vector(64, u8);
    const field_names = comptime std.meta.fieldNames(@TypeOf(needle));
    const len = field_names.len;
    var n_vecs: [len]V = undefined;
    var h_vecs: [len]V = undefined;
    var matches: u64 = 0;
    for (0..len) |i| {
        n_vecs[i] = @splat(@field(needle, field_names[i]));
        h_vecs[i] = @bitCast(@field(haystack, field_names[i]).*);
        matches |= @bitCast(n_vecs[i] != h_vecs[i]);
    }
    return @ctz(matches);
}

// test "Count Starting Matches" {
//     const allo = std.testing.allocator;
//
//     {
//         const rgb: RGB = .{};
//         var rgbs64: std.MultiArrayList(RGB) = try .initCapacity(allo, 64);
//         defer rgbs64.deinit(allo);
//         for (0..64) |_| {
//             rgbs64.appendAssumeCapacity(.{});
//         }
//         const slice = rgbs64.slice();
//         const n_matches64_1 = countStartingMatches(
//             .rgb,
//             rgb,
//             .{ .r = slice.ptrs[0], .g = slice.ptrs[1], .b = slice.ptrs[2] },
//         );
//         const n_matches64_2 = countStartingMatchesSIMD(
//             .rgb,
//             rgb,
//             .{ .r = slice.ptrs[0], .g = slice.ptrs[1], .b = slice.ptrs[2] },
//         );
//         try std.testing.expectEqual(n_matches64_1, 64);
//         try std.testing.expectEqual(n_matches64_2, 64);
//     }
//
//     {
//         const rgb: RGB = .{};
//         var rgbs7: std.MultiArrayList(RGB) = try .initCapacity(allo, 64);
//         defer rgbs7.deinit(allo);
//         for (0..7) |_| rgbs7.appendAssumeCapacity(.{});
//         rgbs7.appendAssumeCapacity(.{ .r = 1, .g = 1, .b = 1 });
//         for (8..64) |_| rgbs7.appendAssumeCapacity(.{});
//
//         const n_matches7_1 = countStartingMatches(.rgb, rgb, &rgbs7);
//         const n_matches7_2 = countStartingMatchesSIMD(.rgb, rgb, &rgbs7);
//         try std.testing.expectEqual(n_matches7_1, 7);
//         try std.testing.expectEqual(n_matches7_2, 7);
//     }
// }

// test "Basic Fns Work How I Expect" {
//     if (px.a == prev.a) {
//         const drgb: RGB = .{
//             .r = px.r -% prev.r,
//             .g = px.g -% prev.g,
//             .b = px.b -% prev.b,
//         };
//         const drgb_dg: RGB = .{
//             .r = drgb.r - drgb.g,
//             .g = drgb.g,
//             .b = drgb.b - drgb.g,
//         };
//         if (drgb.r >= -2 and drgb <= 1 and //
//             dg >= -2 and dg <= 1 and //
//             db >= -2 and db <= 1)
//         {
//             // diff
//             buf[j] = calcDiff(.{ .r = @intCast(dr), .g = @intCast(dg), .b = @intCast(db) });
//             j += 1;
//         } else if (dg >= -32 and dg <= 31 and
//             dr_dg >= -8 and dr_dg <= 7 and
//             db_dg >= -8 and db_dg <= 7)
//         {
//             // luma
//             buf[j] = (@intFromEnum(BitTags.luma) << 6) | (@as(u8, @intCast(dg)) + 32);
//             buf[j + 1] = (@as(u8, @intCast(dr_dg + 8)) << 4) | (@as(u8, @intCast(db_dg)) + 8);
//         } else {
//             // rgb
//             buf[j] = @intFromEnum(ByteTags.rgb);
//             buf[j + 1] = px.r;
//             buf[j + 2] = px.g;
//             buf[j + 3] = px.b;
//             j += 4;
//         }
//     } else {
//         // RGBA
//         buf[j] = @intFromEnum(ByteTags.rgba);
//         buf[j + 1] = px.r;
//         buf[j + 2] = px.g;
//         buf[j + 3] = px.b;
//         buf[j + 4] = px.a;
//         j += 5;
//     }
//     prev = px;
// }
