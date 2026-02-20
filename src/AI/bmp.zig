// const std = @import("std");
// const testing = std.testing;
//
// pub const DecodeError = error{
//     InvalidSignature,
//     InvalidHeader,
//     UnsupportedBitsPerPixel,
//     UnsupportedCompression,
//     UnexpectedEndOfData,
//     InvalidDimensions,
// };
//
// pub const Compression = enum(u32) {
//     none = 0,
//     rle8 = 1,
//     rle4 = 2,
//     bitfields = 3,
// };
//
// pub const BmpHeader = struct {
//     width: u32,
//     height: u32,
//     bits_per_pixel: u16,
//     compression: Compression,
//     top_down: bool,
// };
//
// pub const BmpImage = struct {
//     header: BmpHeader,
//     pixels: []u8,
//     allocator: std.mem.Allocator,
//
//     pub fn deinit(self: *BmpImage) void {
//         self.allocator.free(self.pixels);
//         self.* = undefined;
//     }
//
//     pub fn getPixel(self: *const BmpImage, x: u32, y: u32) struct { r: u8, g: u8, b: u8, a: u8 } {
//         const channels: u32 = if (self.header.bits_per_pixel == 32) 4 else 3;
//         const idx = (y * self.header.width + x) * channels;
//         return .{
//             .r = self.pixels[idx],
//             .g = self.pixels[idx + 1],
//             .b = self.pixels[idx + 2],
//             .a = if (channels == 4) self.pixels[idx + 3] else 0xFF,
//         };
//     }
// };
//
// /// Decode a BMP image from raw bytes in memory.
// pub fn decode(data: []const u8, allocator: std.mem.Allocator) !BmpImage {
//     // Minimum BMP: 14 (file header) + 40 (DIB header) = 54 bytes
//     if (data.len < 54) return DecodeError.InvalidSignature;
//
//     // Validate signature "BM"
//     if (data[0] != 'B' or data[1] != 'M')
//         return DecodeError.InvalidSignature;
//
//     // Parse file header
//     const pixel_data_offset = std.mem.readInt(u32, data[10..14], .little);
//
//     // Parse DIB header (BITMAPINFOHEADER)
//     const dib_header_size = std.mem.readInt(u32, data[14..18], .little);
//     if (dib_header_size < 40) return DecodeError.InvalidHeader;
//
//     const raw_width = std.mem.readInt(i32, data[18..22], .little);
//     const raw_height = std.mem.readInt(i32, data[22..26], .little);
//     const bits_per_pixel = std.mem.readInt(u16, data[28..30], .little);
//     const compression_val = std.mem.readInt(u32, data[30..34], .little);
//
//     if (raw_width <= 0) return DecodeError.InvalidDimensions;
//     if (raw_height == 0) return DecodeError.InvalidDimensions;
//
//     const top_down = raw_height < 0;
//     const width: u32 = @intCast(raw_width);
//     const height: u32 = if (top_down) @intCast(-raw_height) else @intCast(raw_height);
//
//     const compression = std.meta.intToEnum(Compression, compression_val) catch
//         return DecodeError.UnsupportedCompression;
//     if (compression != .none) return DecodeError.UnsupportedCompression;
//
//     // Determine output channels
//     const out_channels: u32 = switch (bits_per_pixel) {
//         8 => 3,
//         24 => 3,
//         32 => 4,
//         else => return DecodeError.UnsupportedBitsPerPixel,
//     };
//
//     // Read color table for 8-bit indexed images
//     var color_table: [256][4]u8 = undefined;
//     if (bits_per_pixel == 8) {
//         const table_offset: usize = 14 + dib_header_size;
//         const table_size: usize = 256 * 4;
//         if (data.len < table_offset + table_size) return DecodeError.UnexpectedEndOfData;
//         for (0..256) |i| {
//             const entry_offset = table_offset + i * 4;
//             color_table[i] = .{
//                 data[entry_offset + 2], // R (stored as BGR in BMP)
//                 data[entry_offset + 1], // G
//                 data[entry_offset + 0], // B
//                 0xFF,
//             };
//         }
//     }
//
//     // Calculate row stride (padded to 4-byte boundary)
//     const row_stride: usize = ((@as(usize, width) * @as(usize, bits_per_pixel) + 31) / 32) * 4;
//
//     // Validate we have enough pixel data
//     if (data.len < pixel_data_offset + row_stride * height)
//         return DecodeError.UnexpectedEndOfData;
//
//     // Allocate output pixel buffer
//     const pixel_data_len: usize = @as(usize, width) * @as(usize, height) * out_channels;
//     const pixels = try allocator.alloc(u8, pixel_data_len);
//     errdefer allocator.free(pixels);
//
//     // Read pixel data row by row
//     for (0..height) |row| {
//         // BMP rows: bottom-up by default, top-down if height was negative
//         const src_row = if (top_down) row else height - 1 - row;
//         const src_offset = pixel_data_offset + src_row * row_stride;
//         const dst_offset = row * @as(usize, width) * out_channels;
//
//         for (0..width) |col| {
//             switch (bits_per_pixel) {
//                 8 => {
//                     const idx = data[src_offset + col];
//                     const entry = color_table[idx];
//                     const dst = dst_offset + col * 3;
//                     pixels[dst] = entry[0];
//                     pixels[dst + 1] = entry[1];
//                     pixels[dst + 2] = entry[2];
//                 },
//                 24 => {
//                     const src = src_offset + col * 3;
//                     const dst = dst_offset + col * 3;
//                     pixels[dst] = data[src + 2]; // R (BMP stores BGR)
//                     pixels[dst + 1] = data[src + 1]; // G
//                     pixels[dst + 2] = data[src]; // B
//                 },
//                 32 => {
//                     const src = src_offset + col * 4;
//                     const dst = dst_offset + col * 4;
//                     pixels[dst] = data[src + 2]; // R (BMP stores BGRA)
//                     pixels[dst + 1] = data[src + 1]; // G
//                     pixels[dst + 2] = data[src]; // B
//                     pixels[dst + 3] = data[src + 3]; // A
//                 },
//                 else => unreachable,
//             }
//         }
//     }
//
//     return BmpImage{
//         .header = .{
//             .width = width,
//             .height = height,
//             .bits_per_pixel = bits_per_pixel,
//             .compression = compression,
//             .top_down = top_down,
//         },
//         .pixels = pixels,
//         .allocator = allocator,
//     };
// }
//
// /// Load a BMP image from a file path.
// pub fn loadFromFile(filepath: []const u8, allocator: std.mem.Allocator) !BmpImage {
//     const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
//     defer file.close();
//
//     const stat = try file.stat();
//     const data = try allocator.alloc(u8, stat.size);
//     defer allocator.free(data);
//
//     const bytes_read = try file.readAll(data);
//     if (bytes_read != stat.size) return DecodeError.UnexpectedEndOfData;
//
//     return decode(data, allocator);
// }
//
// // ─── Unit Tests ─────────────────────────────────────────────────────────
//
// test "decode valid BMP file from disk" {
//     const allocator = testing.allocator;
//     var image = try loadFromFile("src/Images/BasicArt.bmp", allocator);
//     defer image.deinit();
//
//     try testing.expect(image.header.width > 0);
//     try testing.expect(image.header.height > 0);
//
//     const channels: usize = if (image.header.bits_per_pixel == 32) 4 else 3;
//     const expected_len = @as(usize, image.header.width) *
//         @as(usize, image.header.height) * channels;
//     try testing.expectEqual(expected_len, image.pixels.len);
// }
//
// test "reject invalid signature" {
//     const allocator = testing.allocator;
//     var bad = [_]u8{0} ** 54;
//     bad[0] = 'X';
//     bad[1] = 'Y';
//     const result = decode(&bad, allocator);
//     try testing.expectError(DecodeError.InvalidSignature, result);
// }
//
// test "reject truncated data" {
//     const allocator = testing.allocator;
//     const short = [_]u8{ 'B', 'M' };
//     const result = decode(&short, allocator);
//     try testing.expectError(DecodeError.InvalidSignature, result);
// }
//
// test "row padding calculation" {
//     // Row stride for width=1, 24bpp: (1*24+31)/32*4 = 4
//     const stride1: usize = ((1 * 24 + 31) / 32) * 4;
//     try testing.expectEqual(@as(usize, 4), stride1);
//
//     // Row stride for width=2, 24bpp: (2*24+31)/32*4 = 8
//     const stride2: usize = ((2 * 24 + 31) / 32) * 4;
//     try testing.expectEqual(@as(usize, 8), stride2);
//
//     // Row stride for width=3, 24bpp: (3*24+31)/32*4 = 12
//     const stride3: usize = ((3 * 24 + 31) / 32) * 4;
//     try testing.expectEqual(@as(usize, 12), stride3);
//
//     // Row stride for width=5, 24bpp: (5*24+31)/32*4 = 16
//     const stride5: usize = ((5 * 24 + 31) / 32) * 4;
//     try testing.expectEqual(@as(usize, 16), stride5);
// }
