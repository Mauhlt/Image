const std = @import("std");
const Format = @import("Vulkan").Format;
const Image = @import("img.zig");
const RGBA = @import("color.zig").RGBA;
const isSigSame = @import("Misc.zig").isSigSame;

// TODO:
// - track number of pixels - make sure it matches n_pixels
// - track amount of data left - do not go over

// const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
//
// pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
//     if (data.len < 22) return error.InvalidData; // @sizeOf(Header) + @sizeOf(END_MARKER)
//     const hdr: Header = try .decode(data[0..14]);
//     const n_pixels = hdr.width * hdr.height;
//     const pixel_format: Format = blk: switch (hdr.channels) {
//         .rgb => switch (hdr.colorspace) {
//             .linear => break :blk .r8g8b8_snorm,
//             .srgb => break :blk .r8g8b8_srgb,
//         },
//         .rgba => switch (hdr.colorspace) {
//             .linear => break :blk .r8g8b8a8_snorm,
//             .srgb => break :blk .r8g8b8a8_srgb,
//         },
//     };
//     const pixels = try gpa.alloc(RGBA, n_pixels);
//     errdefer gpa.free(pixels);
//
//     const img: Image = .{
//         .width = hdr.width,
//         .height = hdr.height,
//         .pixels = pixels,
//         .format = pixel_format,
//     };
//
//     var prev: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
//     var indices = [_]RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0xFF }} ** 64;
//     var i: usize = @sizeOf(Header) + Header.SIG.len; // position in data
//     var j: usize = 0; // position in pixels
//
//     const len = data.len - 8;
//     while (i < len) {
//         const b1 = data[i];
//         i += 1;
//         const byte_tag: ByteTag = @enumFromInt(b1);
//         switch (byte_tag) {
//             .rgb => {
//                 prev.r = data[i];
//                 prev.g = data[i + 1];
//                 prev.b = data[i + 2];
//             },
//             .rgba => {
//                 prev.r = data[i];
//                 prev.g = data[i + 1];
//                 prev.b = data[i + 2];
//                 prev.a = data[i + 3];
//             },
//             else => {
//                 const bit_tag: BitTag = @enumFromInt(b1 >> 6);
//                 switch (bit_tag) {
//                     .index => {
//                         const idx: u6 = @truncate(b1);
//                         prev = indices[idx];
//                     },
//                     .diff => {
//                         prev.r = prev.r +% (b1 >> 4 & 0x03) -% 2;
//                         prev.g = prev.g +% (b1 >> 2 & 0x03) -% 2;
//                         prev.b = prev.b +% (b1 & 0x03) -% 2;
//                     },
//                     .luma => {
//                         const b2 = data[i];
//                         i += 1;
//                         const dg = @as(i8, @intCast(b1 & 0x3F)) -% 32;
//                         const dr_dg = @as(i8, @intCast(b2 >> 4)) -% 8;
//                         const db_dg = @as(i8, @intCast(b2 & 0x0F)) -% 8;
//                         const dr = dr_dg +% dg;
//                         const db = db_dg +% dg;
//                         prev.r = @bitCast(@as(i8, @bitCast(prev.r)) +% dr);
//                         prev.g = @bitCast(@as(i8, @bitCast(prev.g)) +% dg);
//                         prev.b = @bitCast(@as(i8, @bitCast(prev.b)) +% db);
//                     },
//                     .run => {
//                         const run: u8 = (b1 & 0x3F) + 1;
//                         std.debug.assert(j + run < n_pixels);
//                         switch (img.pixels) {
//                             .rgb => |px| @memset(px[j..][0..run], prev.rgb()),
//                             .rgba => |px| @memset(px[j..][0..run], prev),
//                         }
//                         j += run;
//                         continue; // skip updates to prev + indices
//                     },
//                 }
//             },
//         }
//         // updates
//         indices[hash(prev)] = prev;
//         switch (img.pixels) {
//             .rgb => |px| px[j] = prev.rgb(),
//             .rgba => |px| px[j] = prev,
//         }
//         j += 1;
//     }
//     return img;
// }
//
// pub fn encode(img: *const Image, w: *std.Io.Writer) !void {
//     const hdr: Header = try .fromImage(img);
//     try hdr.encode(w);
//
//     const n_pixels, const overflow = @mulWithOverflow(hdr.width, hdr.height);
//     if (overflow == 1) return error.InvalidDimensions;
//
//     var prev: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
//     // var indices = [_]RGBA{prev} ** 64;
//     var i: usize = 0;
//
//     switch (img.pixels) {
//         .rgb => |pixels| {
//             var n_matches: u8 = 0;
//             while (i < n_pixels) : (i += 1) {
//                 while (i + 64 < n_pixels) {
//                     const px64: @Vector(64, u24) = @as(*const [64]u24, @ptrCast(@alignCast(pixels[i..][0..64]))).*;
//                     const prev64: @Vector(64, u24) = @splat(@as(u24, @bitCast(prev.rgb())));
//                     n_matches = @max(62, @clz(@as(u64, @bitCast(px64 != prev64))));
//                     if (n_matches <= 1) break;
//                     const run: u8 = @as(u8, @intFromEnum(BitTag.run)) << 6 | (n_matches - 1);
//                     try w.writeInt(u8, run, .little);
//                     i += n_matches;
//                 }
//             }
//         },
//         .rgba => |pixels| {
//             _ = pixels;
//             // var n_matches: u8 = 0;
//             // while (i < n_pixels) : (i += 1) {
//             //     while (i + 64 < n_pixels) {
//             //         const px64: @Vector(64, RGBA) = pixels[i..][0..64].*;
//             //         const prev64: @Vector(64, RGBA) = @splat(prev);
//             //     }
//             // }
//         },
//     }
//     //             while (i + 64 <= n_pixels) {
//     //                 const px_64: @Vector(64, u24) = @as([64]u24, @bitCast(pixels[i..][0..64].*));
//     //                 const prev_64: @Vector(64, u24) = @splat(@as(u24, @bitCast(prev.rgb())));
//     //                 n_matches = @max(62, @clz(@as(u64, @bitCast(px_64 != prev_64))));
//     //                 if (n_matches <= 1) break;
//     //                 const run: u8 = @as(u8, @intFromEnum(BitTag.run)) << 6 | (n_matches - 1);
//     //                 try w.writeInt(u8, run, .little);
//     //                 i += n_matches;
//     //             } else {
//     //                 while (i < n_pixels and pixels[i].eql(prev.rgb())) : ({
//     //                     i += 1;
//     //                     n_matches += 1;
//     //                 }) {}
//     //                 if (n_matches > 1) {
//     //                     const run = @as(u8, @intFromEnum(BitTag.run)) << 6 | (n_matches - 1);
//     //                     try w.writeInt(u8, run, .little);
//     //                     i += n_matches;
//     //                 }
//     //             }
//     //             // index
//     //             const px = pixels[i].rgba();
//     //             const idx = hash(px);
//     //             if (indices[idx].eql(px)) {
//     //                 const index = @as(u8, @intFromEnum(BitTag.index)) << 6 | @as(u8, idx);
//     //                 try w.writeInt(u8, index, .little);
//     //                 i += 1;
//     //                 prev = px;
//     //                 continue;
//     //             }
//     //             // diff
//     //             indices[idx] = px;
//     //             const dr = px.r -% prev.r +% 2;
//     //             const dg = px.g -% prev.g +% 2;
//     //             const db = px.b -% prev.b +% 2;
//     //             const dr_dg = dr -% dg;
//     //             const db_dg = db -% dg;
//     //             if (dr <= 3 and dg <= 3 and db <= 3) {
//     //                 const diff = @as(u8, @intFromEnum(BitTag.diff)) << 6 | dr << 4 | dg << 2 | db;
//     //                 try w.writeInt(u8, diff, .little);
//     //                 i += 1;
//     //             } else if (dg >= -32 and dg <= 31 and //
//     //                 dr_dg >= -8 and dr_dg <= 7 and //
//     //                 db_dg >= -8 and db_dg <= 7)
//     //             {
//     //                 const luma1 = @as(u8, @intFromEnum(BitTag.luma)) << 6 | @as(u8, @intCast(dg + 32));
//     //                 const luma2 = @as(u8, @intCast(dr_dg + 8)) << 4 | @as(u8, @intCast(db_dg + 8));
//     //                 try w.writeInt(u8, luma1, .little);
//     //                 try w.writeInt(u8, luma2, .little);
//     //                 i += 2;
//     //             } else {
//     //                 try w.writeInt(u8, @intFromEnum(ByteTag.rgb), .little);
//     //                 try w.writeInt(u8, px.r, .little);
//     //                 try w.writeInt(u8, px.g, .little);
//     //                 try w.writeInt(u8, px.b, .little);
//     //                 i += 4;
//     //             }
//     //             prev = px;
//     //         }
//     //     },
//     //     .rgba => |pixels| {
//     //         std.debug.print("RGBA\n", .{});
//     //         while (i < n_pixels) : (i += 1) {
//     //             // run
//     //             var n_matches: u8 = 0;
//     //             while (i + 64 <= n_pixels) {
//     //                 const px_64: @Vector(64, u32) = @bitCast(pixels[i..][0..64].*);
//     //                 const prev_64: @Vector(64, u32) = @splat(@as(u32, @bitCast(prev)));
//     //                 n_matches = @max(62, @clz(@as(u64, @bitCast(px_64 != prev_64))));
//     //                 if (n_matches <= 1) break;
//     //                 const run: u8 = @as(u8, @intFromEnum(BitTag.run)) << 6 | (n_matches - 1);
//     //                 try w.writeInt(u8, run, .little);
//     //                 i += n_matches;
//     //             } else {
//     //                 while (i < n_pixels and pixels[i].eql(prev)) : ({
//     //                     i += 1;
//     //                     n_matches += 1;
//     //                 }) {}
//     //                 if (n_matches > 1) {
//     //                     const run = @as(u8, @intFromEnum(BitTag.run)) << 6 | (n_matches - 1);
//     //                     try w.writeInt(u8, run, .little);
//     //                     i += n_matches;
//     //                 }
//     //             }
//     //             const px = pixels[i];
//     //             // index
//     //             const idx = hash(px);
//     //             if (indices[idx].eql(px)) {
//     //                 const index = @as(u8, @intFromEnum(BitTag.index)) << 6 | @as(u8, idx);
//     //                 try w.writeInt(u8, index, .little);
//     //                 i += 1;
//     //                 prev = px;
//     //                 continue;
//     //             }
//     //             indices[idx] = px;
//     //             if (px.a == prev.a) {
//     //                 const dr = px.r - prev.r;
//     //                 const dg = px.g - prev.g;
//     //                 const db = px.b - prev.b;
//     //                 const dr_dg = dr - dg;
//     //                 const db_dg = db - dg;
//     //                 if (dr >= -2 and dr <= 1 and //
//     //                     dg >= -2 and dg <= 1 and //
//     //                     db >= -2 and db <= 1)
//     //                 { // diff
//     //                     const diff = @as(u8, @intFromEnum(BitTag.diff)) << 6 |
//     //                         @as(u8, @intCast(dr + 2)) << 4 |
//     //                         @as(u8, @intCast(dg + 2)) << 2 |
//     //                         @as(u8, @intCast(db + 2));
//     //                     try w.writeInt(u8, diff, .little);
//     //                     i += 1;
//     //                 } else if (dg >= -32 and dg <= 31 and
//     //                     dr_dg >= -8 and dr_dg <= 7 and
//     //                     db_dg >= -8 and db_dg <= 7)
//     //                 { // luma
//     //                     const luma1 = @as(u8, @intFromEnum(BitTag.luma)) << 6 | @as(u8, @intCast(dg + 32));
//     //                     const luma2 = @as(u8, @intCast(dr_dg + 8)) << 4 | @as(u8, @intCast(db_dg + 8));
//     //                     try w.writeInt(u8, luma1, .little);
//     //                     try w.writeInt(u8, luma2, .little);
//     //                 } else { // rgb
//     //                     try w.writeInt(u8, @intFromEnum(ByteTag.rgb), .little);
//     //                     try w.writeInt(u8, px.r, .little);
//     //                     try w.writeInt(u8, px.g, .little);
//     //                     try w.writeInt(u8, px.b, .little);
//     //                 }
//     //             } else { // rgba
//     //                 try w.writeInt(u8, @intFromEnum(ByteTag.rgba), .little);
//     //                 try w.writeInt(u8, px.r, .little);
//     //                 try w.writeInt(u8, px.g, .little);
//     //                 try w.writeInt(u8, px.b, .little);
//     //                 try w.writeInt(u8, px.a, .little);
//     //             }
//     //             prev = px;
//     //         }
//     //     },
//     // }
//     try w.writeAll(&END_MARKER);
// }
//
// const ByteTag = enum(u8) {
//     rgb = 0xFE,
//     rgba = 0xFF,
//     _,
// };
//
// const BitTag = enum(u2) {
//     index = 0,
//     diff = 1,
//     luma = 2,
//     run = 3,
// };
//
// fn hash(c: RGBA) u6 {
//     return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
// }
//
// const Channels = enum(u8) {
//     rgb = 3,
//     rgba = 4,
// };
//
// const Colorspace = enum(u8) {
//     srgb = 0,
//     linear = 1,
// };
//
// const Header = struct {
//     pub const SIG = "qoif";
//     width: u32,
//     height: u32,
//     channels: Channels,
//     colorspace: Colorspace,
//
//     pub fn fromImage(img: *const Image) !@This() {
//         std.debug.assert(img.extent.depth <= 1);
//         const channels: Channels = switch (img.pixel_format) {
//             .r8g8b8_srgb, .r8g8b8_snorm, .b8g8r8_srgb, .b8g8r8_snorm => .rgb,
//             .r8g8b8a8_srgb, .r8g8b8a8_snorm, .b8g8r8a8_srgb, .b8g8r8a8_snorm => .rgba,
//             else => {
//                 std.debug.print("{t}\n", .{img.pixel_format});
//                 unreachable;
//             },
//         };
//         const colorspace: Colorspace = switch (img.pixel_format) {
//             .r8g8b8_snorm, .r8g8b8a8_snorm, .b8g8r8_snorm, .b8g8r8a8_snorm => .linear,
//             .r8g8b8_srgb, .r8g8b8a8_srgb, .b8g8r8_srgb, .b8g8r8a8_srgb => .srgb,
//             else => {
//                 std.debug.print("{t}\n", .{img.pixel_format});
//                 unreachable;
//             },
//         };
//         return .{
//             .width = img.extent.width,
//             .height = img.extent.height,
//             .channels = channels,
//             .colorspace = colorspace,
//         };
//     }
//
//     pub fn decode(data: []const u8) !@This() {
//         try isSigSame(data[0..4], SIG);
//         const width = std.mem.readInt(u32, data[4..][0..4], .big);
//         const height = std.mem.readInt(u32, data[8..][0..4], .big);
//         if (width == 0 or height == 0) return error.InvalidDimensions;
//         _, const overflow: u1 = @mulWithOverflow(width, height);
//         if (overflow == 1) return error.InvalidDimensions;
//         const channels = std.enums.fromInt(Channels, data[12]) orelse
//             return error.InvalidChannel;
//         const colorspace = std.enums.fromInt(Colorspace, data[13]) orelse
//             return error.InvalidColorspace;
//         return .{
//             .width = width,
//             .height = height,
//             .channels = channels,
//             .colorspace = colorspace,
//         };
//     }
//
//     pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
//         try w.writeAll("qoif");
//         try w.writeInt(u32, self.width, .big);
//         try w.writeInt(u32, self.height, .big);
//         try w.writeInt(u8, @intFromEnum(self.channels), .little);
//         try w.writeInt(u8, @intFromEnum(self.colorspace), .little);
//     }
// };
