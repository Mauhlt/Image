// const std = @import("std");
// const Format = @import("Vulkan").Format;
// const Error = @import("../error.zig");
//
// const Header = @import("header.zig");
//
// const Image = @import("../../root.zig");
// const RGB = @import("../../Colors/pixel_format.zig").RGB;
// const RGBA = @import("../../Colors/pixel_format.zig").RGBA;
// const Pixels = @import("../../Colors/Pixels.zig").Pixels;
//
// const SIG = @import("misc.zig").SIG;
//
// const findFirstMatches = @import("matches.zig").findFirstMatches;
// const findFirstMatchesSIMD = @import("matches.zig").findFirstMatchesSIMD;
//
// const HASH_TABLE_SIZE = 64;
// pub const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
//
// pub const ByteTags = enum(u8) {
//     rgb = 0xFE,
//     rgba = 0xFF,
//     _,
// };
//
// pub const BitTags = enum(u2) {
//     index = 0,
//     diff = 1,
//     luma = 2,
//     run = 3,
// };
//
// inline fn hashRGB(rgb: RGB) u6 {
//     return @truncate(rgb.red *% 3 +% //
//         rgb.green *% 5 +% //
//         rgb.blue *% 7);
// }
//
// inline fn hashRGBA(rgba: RGBA) u6 {
//     return @truncate(rgba.red *% 3 +% //
//         rgba.green *% 5 +% //
//         rgba.blue *% 7 +% //
//         rgba.alpha *% 11);
// }
//
// pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
//     const hdr: Header = try .decode(data);
//     const fmt: Format = switch (hdr.channel) {
//         .rgb => switch (hdr.colorspace) {
//             .srgb => .r8g8b8_srgb,
//             .linear => .r8g8b8_uint,
//         },
//         .rgba => switch (hdr.colorspace) {
//             .srgb => .r8g8b8a8_srgb,
//             .linear => .r8g8b8a8_uint,
//         },
//     };
//     const n_pixels, const overflow = @mulWithOverflow(hdr.width, hdr.height);
//     if (overflow > 0) return error.ImageDimensionOverflow;
//     const pixels_slice = data[14 .. data.len - END_MARKER.len];
//     const pixels: Pixels = switch (hdr.channel) {
//         .rgb => try decodeRgb(gpa, n_pixels, pixels_slice),
//         .rgba => try decodeRgba(gpa, n_pixels, pixels_slice),
//     };
//     errdefer pixels.deinit(gpa);
//     for (data[data.len - END_MARKER.len ..], END_MARKER) |dem, em| {
//         if (dem != em) return error.InvalidEndMarker;
//     }
//     return .{
//         .fmt = fmt,
//         .width = hdr.width,
//         .height = hdr.height,
//         .pixels = pixels,
//     };
// }
//
// pub fn encode(img: *const Image, w: *std.Io.Writer) !void {
//     const hdr: Header = try .fromImage(img);
//     try hdr.encode(w);
//     switch (img.pixels) {
//         .rgbs => |rgbs| try encodeRgb(w, rgbs),
//         .rgbas => |rgbas| try encodeRgba(w, rgbas),
//         else => unreachable,
//     }
//     try w.writeAll(END_MARKER[0..END_MARKER.len]);
//     try w.flush();
// }
//
// fn decodeRgb(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !Pixels {
//     var rgb_pxs: Pixels = try .initEmpty(gpa, .rgbs, n_pixels);
//     errdefer rgb_pxs.deinit(gpa);
//     var prev: RGB = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var px: RGB = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var table = [_]RGB{.{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     }} ** HASH_TABLE_SIZE;
//     var i: usize = 0; // data idx
//     var j: usize = 0; // rgbs idx
//     while (i < data.len) : (i += 1) {
//         const byte1 = data[i];
//         switch (@as(ByteTags, @enumFromInt(byte1))) {
//             .rgb => {
//                 if (i + 3 >= data.len) return error.OutOfBounds;
//                 px.red = data[i + 1];
//                 px.green = data[i + 2];
//                 px.blue = data[i + 3];
//                 i += 3;
//             },
//             .rgba => return error.InvalidByteTag,
//             else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
//                 .run => {
//                     const run = (byte1 & 0x3F) + 1;
//                     if (j + run > n_pixels) return error.OutOfBounds;
//                     @memset(rgb_pxs.rgbs[j..][0..run], prev);
//                     j += run;
//                     continue;
//                 },
//                 .index => {
//                     const index = byte1 & 0x3F;
//                     px = table[index];
//                 },
//                 .diff => {
//                     px.red = prev.red +% ((byte1 >> 4) & 0x03) -% 2;
//                     px.green = prev.green +% ((byte1 >> 2) & 0x03) -% 2;
//                     px.blue = prev.blue +% (byte1 & 0x03) -% 2;
//                 },
//                 .luma => {
//                     i += 1;
//                     if (i >= data.len) return error.OutOfBounds;
//                     const byte2 = data[i];
//                     const drgb: RGB = .{
//                         .red = ((byte2 & 0xF0) >> 4) +% (byte1 & 0x3F),
//                         .green = (byte1 & 0x3F),
//                         .blue = (byte2 & 0x0F) +% (byte1 & 0x3F),
//                     };
//                     px.red = prev.red +% drgb.red -% 40;
//                     px.green = prev.green +% drgb.green -% 32;
//                     px.blue = prev.blue +% drgb.blue -% 40;
//                 },
//             }
//         }
//         prev = px;
//         table[hashRGB(px)] = px;
//         if (j > n_pixels) return error.PixelOutOfBound;
//         rgb_pxs.rgbs[j] = px;
//         j += 1;
//     }
//     if (rgb_pxs.rgbs.len != n_pixels) return error.MismatchInNumberOfPixels;
//     return rgb_pxs;
// }
//
// fn decodeRgba(gpa: std.mem.Allocator, n_pixels: u32, data: []const u8) !Pixels {
//     const rgba_pxs: Pixels = try .initEmpty(gpa, .rgbas, n_pixels);
//     errdefer rgba_pxs.deinit(gpa);
//     var prev: RGBA = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var px: RGBA = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var table = [_]RGBA{.{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     }} ** HASH_TABLE_SIZE;
//     var i: usize = 0; // data idx
//     var j: usize = 0; // rgbas idx
//     while (i < data.len) : (i += 1) {
//         const byte1 = data[i];
//         switch (@as(ByteTags, @enumFromInt(byte1))) {
//             .rgb => {
//                 if (i + 3 >= data.len) return error.OutOfBounds;
//                 px.red = data[i + 1];
//                 px.green = data[i + 2];
//                 px.blue = data[i + 3];
//                 i += 3;
//             },
//             .rgba => {
//                 if (i + 4 >= data.len) return error.OutOfBounds;
//                 px.red = data[i + 1];
//                 px.green = data[i + 2];
//                 px.blue = data[i + 3];
//                 px.alpha = data[i + 4];
//                 i += 4;
//             },
//             else => switch (@as(BitTags, @enumFromInt(byte1 >> 6))) {
//                 .run => {
//                     const run = (byte1 & 0x3F) + 1;
//                     if (j + run > n_pixels) return error.OutOfBounds;
//                     @memset(rgba_pxs.rgbas[j..][0..run], prev);
//                     j += run;
//                     continue;
//                 },
//                 .index => {
//                     const index = byte1 & 0x3F;
//                     px = table[index];
//                 },
//                 .diff => {
//                     px.red = prev.red +% ((byte1 >> 4) & 0x03) -% 2;
//                     px.green = prev.green +% ((byte1 >> 2) & 0x03) -% 2;
//                     px.blue = prev.blue +% (byte1 & 0x03) -% 2;
//                 },
//                 .luma => {
//                     i += 1;
//                     if (i >= data.len) return error.OutOfBounds;
//                     const byte2 = data[i];
//                     const drgb: RGB = .{
//                         .red = ((byte2 & 0xF0) >> 4) +% (byte1 & 0x3F),
//                         .green = byte1 & 0x3F,
//                         .blue = ((byte2 & 0x0F)) +% (byte1 & 0x3F),
//                     };
//                     px.red = prev.red +% drgb.red -% 40;
//                     px.green = prev.green +% drgb.green -% 32;
//                     px.blue = prev.blue +% drgb.blue -% 40;
//                 },
//             }
//         }
//         prev = px;
//         table[hashRGBA(px)] = px;
//         if (j > n_pixels) return error.PixelOutOfBound;
//         rgba_pxs.rgbas[j] = px;
//         j += 1;
//     }
//     if (rgba_pxs.rgbas.len != n_pixels) return error.MismatchInNumberOfPixels;
//     return rgba_pxs;
// }
//
// fn encodeRgb(w: *std.Io.Writer, rgbs: []RGB) !void {
//     var px: RGB = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var prev: RGB = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var table = [_]RGB{.{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     }} ** HASH_TABLE_SIZE;
//     var i: usize = 0;
//     const len = rgbs.len;
//     while (i < len) : (i += 1) {
//         px = rgbs[i];
//         defer prev = px;
//         const n = if (i + 64 < rgbs.len)
//             findFirstMatchesSIMD(RGB, rgbs[i..][0..64], prev)
//         else
//             findFirstMatches(RGB, rgbs[i..], prev);
//         if (n > 1) {
//             const run = @min(n, 62) - 1; // 1..62
//             const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
//             try w.writeByte(byte);
//             // std.debug.print("run ", .{});
//             i += run;
//             continue;
//         }
//
//         const index = hashRGB(px);
//         if (table[index].eql(px)) {
//             const byte = (@as(u8, @intFromEnum(BitTags.index)) << 6) | index;
//             try w.writeByte(byte);
//             // std.debug.print("index ", .{});
//             continue;
//         }
//         table[index] = px;
//
//         const drgb: RGB = .{
//             .red = px.red -% prev.red,
//             .green = px.green -% prev.green,
//             .blue = px.blue -% prev.blue,
//         };
//         if ((drgb.red +% 2) < 4 and (drgb.green +% 2) < 4 and (drgb.blue +% 2) < 4) {
//             const byte = (@as(u8, @intFromEnum(BitTags.diff)) << 6) | //
//                 ((drgb.red +% 2) & 0x03) << 4 | //
//                 ((drgb.green +% 2) & 0x03) << 2 | //
//                 ((drgb.blue +% 2) & 0x03);
//             try w.writeByte(byte);
//             // std.debug.print("diff ", .{});
//             continue;
//         }
//
//         const dg2 = drgb.green +% 32;
//         const drdg = drgb.red -% drgb.green +% 8;
//         const dbdg = drgb.blue -% drgb.green +% 8;
//         if (dg2 < 64 and drdg < 16 and dbdg < 16) {
//             const byte1 = (@as(u8, @intFromEnum(BitTags.luma)) << 6) | dg2;
//             const byte2 = (drdg << 4) | dbdg;
//             try w.writeByte(byte1);
//             try w.writeByte(byte2);
//             // std.debug.print("luma ", .{});
//             continue;
//         }
//
//         const byte = @as(u8, @intFromEnum(ByteTags.rgb));
//         try w.writeByte(byte);
//         try w.writeByte(px.red);
//         try w.writeByte(px.green);
//         try w.writeByte(px.blue);
//         // std.debug.print("rgb ", .{});
//     }
//     // std.debug.print("\n", .{});
// }
//
// fn encodeRgba(w: *std.Io.Writer, rgbas: []RGBA) !void {
//     var px: RGBA = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var prev: RGBA = .{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     };
//     var table = [_]RGBA{.{
//         .red = 0,
//         .green = 0,
//         .blue = 0,
//     }} ** HASH_TABLE_SIZE;
//     var i: usize = 0;
//     // std.debug.print("Encode RGBA: ", .{});
//
//     while (i < rgbas.len) : (i += 1) {
//         px = rgbas[i];
//         defer prev = px;
//
//         const n = if (i + 64 < rgbas.len)
//             findFirstMatchesSIMD(RGBA, rgbas[i..][0..64], prev)
//         else
//             findFirstMatches(RGBA, rgbas[i..], prev);
//         if (n > 1) {
//             // std.debug.print("run ", .{});
//             const run = @min(n, 62) - 1;
//             const byte = (@as(u8, @intFromEnum(BitTags.run)) << 6) | run;
//             try w.writeByte(byte);
//             i += run;
//             continue;
//         }
//
//         const index = hashRGBA(px);
//         if (table[index].eql(px)) {
//             // std.debug.print("index ", .{});
//             const byte = @as(u8, @intFromEnum(BitTags.index)) << 6 | index;
//             try w.writeByte(byte);
//             continue;
//         }
//         table[index] = px;
//
//         if (px.alpha == prev.alpha) {
//             const dr = px.red -% prev.red;
//             const dg = px.green -% prev.green;
//             const db = px.blue -% prev.blue;
//
//             if ((dr +% 2) < 4 and (dg +% 2) < 4 and (db +% 2) < 4) {
//                 // std.debug.print("diff ", .{});
//                 const byte = @as(u8, //
//                     @intFromEnum(BitTags.diff)) << 6 | //
//                     (((dr +% 2) & 0x03) << 4) | //
//                     (((dg +% 2) & 0x03) << 2) | //
//                     ((db +% 2) & 0x03);
//                 try w.writeByte(byte);
//                 continue;
//             }
//
//             const dg2 = dg +% 32;
//             const drdg = dr -% dg +% 8;
//             const dbdg = db -% dg +% 8;
//             if (dg2 < 64 and drdg < 16 and dbdg < 16) {
//                 // std.debug.print("luma ", .{});
//                 const byte1 = (@as(u8, @intFromEnum(BitTags.luma)) << 6) | dg2;
//                 const byte2 = (drdg << 4) | dbdg;
//                 try w.writeByte(byte1);
//                 try w.writeByte(byte2);
//                 // std.debug.print("luma ", .{});
//                 continue;
//             }
//
//             // std.debug.print("rgb ", .{});
//             const byte1 = @intFromEnum(ByteTags.rgb);
//             try w.writeByte(byte1);
//             try w.writeByte(px.red);
//             try w.writeByte(px.green);
//             try w.writeByte(px.blue);
//         } else {
//             // std.debug.print("rgba ", .{});
//             const byte1 = @intFromEnum(ByteTags.rgba);
//             try w.writeByte(byte1);
//             try w.writeByte(px.red);
//             try w.writeByte(px.green);
//             try w.writeByte(px.blue);
//             try w.writeByte(px.alpha);
//         }
//     }
// }
