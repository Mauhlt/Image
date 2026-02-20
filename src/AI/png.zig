// const std = @import("std");
// const testing = std.testing;
//
// pub const DecodeError = error{
//     InvalidSignature,
//     InvalidIHDR,
//     UnsupportedColorType,
//     UnsupportedBitDepth,
//     UnsupportedInterlace,
//     InvalidFilterType,
//     DecompressionFailed,
//     NoIDATChunks,
//     UnexpectedEndOfData,
//     InvalidDimensions,
// };
//
// pub const ColorType = enum(u8) {
//     grayscale = 0,
//     truecolor = 2,
//     indexed = 3,
//     grayscale_alpha = 4,
//     truecolor_alpha = 6,
//
//     pub fn channels(self: ColorType) u8 {
//         return switch (self) {
//             .grayscale => 1,
//             .truecolor => 3,
//             .indexed => 1,
//             .grayscale_alpha => 2,
//             .truecolor_alpha => 4,
//         };
//     }
// };
//
// pub const PngHeader = struct {
//     width: u32,
//     height: u32,
//     bit_depth: u8,
//     color_type: ColorType,
//     interlace: u8,
// };
//
// pub const PngImage = struct {
//     header: PngHeader,
//     pixels: []u8,
//     allocator: std.mem.Allocator,
//
//     pub fn deinit(self: *PngImage) void {
//         self.allocator.free(self.pixels);
//         self.* = undefined;
//     }
//
//     pub fn getPixel(self: *const PngImage, x: u32, y: u32) struct { r: u8, g: u8, b: u8, a: u8 } {
//         const ch: u32 = self.header.color_type.channels();
//         const idx = (y * self.header.width + x) * ch;
//         return switch (self.header.color_type) {
//             .grayscale => .{ .r = self.pixels[idx], .g = self.pixels[idx], .b = self.pixels[idx], .a = 0xFF },
//             .truecolor => .{ .r = self.pixels[idx], .g = self.pixels[idx + 1], .b = self.pixels[idx + 2], .a = 0xFF },
//             .grayscale_alpha => .{ .r = self.pixels[idx], .g = self.pixels[idx], .b = self.pixels[idx], .a = self.pixels[idx + 1] },
//             .truecolor_alpha => .{ .r = self.pixels[idx], .g = self.pixels[idx + 1], .b = self.pixels[idx + 2], .a = self.pixels[idx + 3] },
//             .indexed => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
//         };
//     }
// };
//
// const png_signature = [8]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
//
// fn paethPredictor(a_raw: u8, b_raw: u8, c_raw: u8) u8 {
//     const a: i16 = a_raw;
//     const b: i16 = b_raw;
//     const c: i16 = c_raw;
//     const p: i16 = a + b - c;
//     const pa = @abs(p - a);
//     const pb = @abs(p - b);
//     const pc = @abs(p - c);
//     if (pa <= pb and pa <= pc) return a_raw;
//     if (pb <= pc) return b_raw;
//     return c_raw;
// }
//
// fn unfilterScanlines(raw: []u8, width: u32, height: u32, bpp: u8) DecodeError![]u8 {
//     const stride: usize = @as(usize, width) * bpp;
//     // raw should contain height * (1 + stride) bytes: 1 filter byte per row + pixel data
//     const expected_len = @as(usize, height) * (1 + stride);
//     if (raw.len < expected_len) return DecodeError.UnexpectedEndOfData;
//
//     // Unfilter in-place, writing output into a contiguous pixel buffer
//     // We'll work row by row. The raw layout is: [filter_byte | stride bytes] per row.
//     var row: usize = 0;
//     while (row < height) : (row += 1) {
//         const row_start = row * (1 + stride);
//         const filter_type = raw[row_start];
//         const scanline = raw[row_start + 1 .. row_start + 1 + stride];
//
//         const prior_row: ?[]const u8 = if (row > 0)
//             raw[(row - 1) * (1 + stride) + 1 .. (row - 1) * (1 + stride) + 1 + stride]
//         else
//             null;
//
//         switch (filter_type) {
//             0 => {}, // None
//             1 => {
//                 // Sub
//                 var i: usize = bpp;
//                 while (i < stride) : (i += 1) {
//                     scanline[i] = scanline[i] +% scanline[i - bpp];
//                 }
//             },
//             2 => {
//                 // Up
//                 if (prior_row) |prior| {
//                     var i: usize = 0;
//                     while (i < stride) : (i += 1) {
//                         scanline[i] = scanline[i] +% prior[i];
//                     }
//                 }
//             },
//             3 => {
//                 // Average
//                 var i: usize = 0;
//                 while (i < stride) : (i += 1) {
//                     const a: u16 = if (i >= bpp) scanline[i - bpp] else 0;
//                     const b: u16 = if (prior_row) |prior| prior[i] else 0;
//                     scanline[i] = scanline[i] +% @as(u8, @intCast((a + b) / 2));
//                 }
//             },
//             4 => {
//                 // Paeth
//                 var i: usize = 0;
//                 while (i < stride) : (i += 1) {
//                     const a: u8 = if (i >= bpp) scanline[i - bpp] else 0;
//                     const b: u8 = if (prior_row) |prior| prior[i] else 0;
//                     const c: u8 = if (i >= bpp) (if (prior_row) |prior| prior[i - bpp] else 0) else 0;
//                     scanline[i] = scanline[i] +% paethPredictor(a, b, c);
//                 }
//             },
//             else => return DecodeError.InvalidFilterType,
//         }
//     }
//
//     return raw[0..expected_len];
// }
//
// /// Decode a PNG image from raw bytes in memory.
// pub fn decode(data: []const u8, allocator: std.mem.Allocator) !PngImage {
//     if (data.len < 8) return DecodeError.InvalidSignature;
//     if (!std.mem.eql(u8, data[0..8], &png_signature))
//         return DecodeError.InvalidSignature;
//
//     var pos: usize = 8;
//
//     var header: ?PngHeader = null;
//     var idat_chunks: std.ArrayListUnmanaged([]const u8) = .{};
//     defer idat_chunks.deinit(allocator);
//     var total_idat_len: usize = 0;
//
//     // Parse chunks
//     while (pos + 12 <= data.len) {
//         const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
//         const chunk_type = data[pos + 4 .. pos + 8];
//         const chunk_data_start = pos + 8;
//         const chunk_end = chunk_data_start + chunk_len + 4; // +4 for CRC
//
//         if (chunk_end > data.len) return DecodeError.UnexpectedEndOfData;
//
//         if (std.mem.eql(u8, chunk_type, "IHDR")) {
//             if (chunk_len != 13) return DecodeError.InvalidIHDR;
//             const d = data[chunk_data_start..];
//             const width = std.mem.readInt(u32, d[0..4], .big);
//             const height = std.mem.readInt(u32, d[4..8], .big);
//             const bit_depth = d[8];
//             const color_type_byte = d[9];
//             // d[10] = compression, d[11] = filter method (both must be 0)
//             const interlace = d[12];
//
//             if (width == 0 or height == 0) return DecodeError.InvalidDimensions;
//             if (bit_depth != 8) return DecodeError.UnsupportedBitDepth;
//             if (interlace != 0) return DecodeError.UnsupportedInterlace;
//
//             const color_type = std.meta.intToEnum(ColorType, color_type_byte) catch
//                 return DecodeError.UnsupportedColorType;
//             if (color_type == .indexed) return DecodeError.UnsupportedColorType;
//
//             header = .{
//                 .width = width,
//                 .height = height,
//                 .bit_depth = bit_depth,
//                 .color_type = color_type,
//                 .interlace = interlace,
//             };
//         } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
//             try idat_chunks.append(allocator, data[chunk_data_start .. chunk_data_start + chunk_len]);
//             total_idat_len += chunk_len;
//         } else if (std.mem.eql(u8, chunk_type, "IEND")) {
//             break;
//         }
//
//         pos = chunk_end;
//     }
//
//     const hdr = header orelse return DecodeError.InvalidIHDR;
//     if (idat_chunks.items.len == 0) return DecodeError.NoIDATChunks;
//
//     // Concatenate all IDAT data
//     const compressed = try allocator.alloc(u8, total_idat_len);
//     defer allocator.free(compressed);
//     {
//         var offset: usize = 0;
//         for (idat_chunks.items) |chunk| {
//             @memcpy(compressed[offset .. offset + chunk.len], chunk);
//             offset += chunk.len;
//         }
//     }
//
//     // Decompress using zlib
//     const bpp: u8 = hdr.color_type.channels();
//     const stride: usize = @as(usize, hdr.width) * bpp;
//     const raw_len: usize = @as(usize, hdr.height) * (1 + stride);
//
//     const raw = try allocator.alloc(u8, raw_len);
//     defer allocator.free(raw);
//
//     var input_reader: std.Io.Reader = .fixed(compressed);
//     const window_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
//     defer allocator.free(window_buf);
//     var decompressor: std.compress.flate.Decompress = .init(&input_reader, .zlib, window_buf);
//     decompressor.reader.readSliceAll(raw) catch
//         return DecodeError.DecompressionFailed;
//
//     // Unfilter scanlines
//     _ = try unfilterScanlines(raw, hdr.width, hdr.height, bpp);
//
//     // Copy pixel data (strip filter bytes)
//     const pixel_data_len: usize = @as(usize, hdr.width) * @as(usize, hdr.height) * bpp;
//     const pixels = try allocator.alloc(u8, pixel_data_len);
//     errdefer allocator.free(pixels);
//
//     var row: usize = 0;
//     while (row < hdr.height) : (row += 1) {
//         const src_start = row * (1 + stride) + 1; // +1 to skip filter byte
//         const dst_start = row * stride;
//         @memcpy(pixels[dst_start .. dst_start + stride], raw[src_start .. src_start + stride]);
//     }
//
//     return PngImage{
//         .header = hdr,
//         .pixels = pixels,
//         .allocator = allocator,
//     };
// }
//
// /// Load a PNG image from a file path.
// pub fn loadFromFile(filepath: []const u8, allocator: std.mem.Allocator) !PngImage {
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
// test "decode valid PNG file from disk" {
//     const allocator = testing.allocator;
//     var image = try loadFromFile("src/Images/BasicArt.png", allocator);
//     defer image.deinit();
//
//     try testing.expect(image.header.width > 0);
//     try testing.expect(image.header.height > 0);
//     try testing.expect(image.header.bit_depth == 8);
//
//     const expected_len = @as(usize, image.header.width) *
//         @as(usize, image.header.height) *
//         image.header.color_type.channels();
//     try testing.expectEqual(expected_len, image.pixels.len);
// }
//
// test "reject invalid signature" {
//     const allocator = testing.allocator;
//     var bad = [_]u8{0} ** 24;
//     bad[0] = 'b';
//     bad[1] = 'a';
//     bad[2] = 'd';
//     bad[3] = '!';
//     const result = decode(&bad, allocator);
//     try testing.expectError(DecodeError.InvalidSignature, result);
// }
//
// test "reject truncated data" {
//     const allocator = testing.allocator;
//     // Valid signature but nothing else
//     const short = png_signature;
//     const result = decode(&short, allocator);
//     try testing.expectError(DecodeError.InvalidIHDR, result);
// }
//
// test "paeth predictor correctness" {
//     // When a=0, b=0, c=0, should return 0
//     try testing.expectEqual(@as(u8, 0), paethPredictor(0, 0, 0));
//
//     // When a=10, b=20, c=5: p=25, pa=15, pb=5, pc=20 -> b wins
//     try testing.expectEqual(@as(u8, 20), paethPredictor(10, 20, 5));
//
//     // When a=100, b=50, c=80: p=70, pa=30, pb=20, pc=10 -> c wins
//     try testing.expectEqual(@as(u8, 80), paethPredictor(100, 50, 80));
//
//     // When a=200, b=100, c=150: p=150, pa=50, pb=50, pc=0 -> c wins
//     try testing.expectEqual(@as(u8, 150), paethPredictor(200, 100, 150));
// }
