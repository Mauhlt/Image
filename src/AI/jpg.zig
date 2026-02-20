// const std = @import("std");
// const testing = std.testing;
// const math = std.math;
//
// pub const DecodeError = error{
//     InvalidSignature,
//     InvalidHeader,
//     InvalidData,
//     UnsupportedFormat,
//     UnexpectedEndOfData,
//     InvalidHuffmanCode,
//     InvalidDimensions,
//     InvalidMarker,
// };
//
// pub const JpgHeader = struct {
//     width: u32,
//     height: u32,
//     num_components: u8,
//     precision: u8,
// };
//
// pub const JpgImage = struct {
//     header: JpgHeader,
//     pixels: []u8,
//     allocator: std.mem.Allocator,
//
//     pub fn deinit(self: *JpgImage) void {
//         self.allocator.free(self.pixels);
//         self.* = undefined;
//     }
//
//     pub fn getPixel(self: *const JpgImage, x: u32, y: u32) struct { r: u8, g: u8, b: u8 } {
//         const idx = (y * self.header.width + x) * 3;
//         return .{
//             .r = self.pixels[idx],
//             .g = self.pixels[idx + 1],
//             .b = self.pixels[idx + 2],
//         };
//     }
// };
//
// // Zigzag scan order: maps zigzag index to row-major 8x8 position
// const zigzag_map = [64]u8{
//     0,  1,  8,  16, 9,  2,  3,  10,
//     17, 24, 32, 25, 18, 11, 4,  5,
//     12, 19, 26, 33, 40, 48, 41, 34,
//     27, 20, 13, 6,  7,  14, 21, 28,
//     35, 42, 49, 56, 57, 50, 43, 36,
//     29, 22, 15, 23, 30, 37, 44, 51,
//     58, 59, 52, 45, 38, 31, 39, 46,
//     53, 60, 61, 54, 47, 55, 62, 63,
// };
//
// const inv_sqrt2: f64 = 1.0 / @sqrt(2.0);
//
// // Comptime cosine lookup: cos((2*x+1)*u*pi/16)
// const idct_cosines: [8][8]f64 = blk: {
//     var table: [8][8]f64 = undefined;
//     for (0..8) |u_idx| {
//         for (0..8) |x| {
//             table[u_idx][x] = @cos(
//                 @as(f64, @floatFromInt(2 * x + 1)) *
//                     @as(f64, @floatFromInt(u_idx)) *
//                     math.pi / 16.0,
//             );
//         }
//     }
//     break :blk table;
// };
//
// // Huffman table
// const HuffmanTable = struct {
//     min_code: [17]i32,
//     max_code: [17]i32,
//     val_offset: [17]i32,
//     values: [256]u8,
//     num_values: u16,
// };
//
// // Component descriptor from SOF
// const Component = struct {
//     id: u8,
//     h_sampling: u8,
//     v_sampling: u8,
//     quant_table_id: u8,
// };
//
// // Scan component from SOS
// const ScanComponent = struct {
//     component_idx: u8,
//     dc_table_id: u8,
//     ac_table_id: u8,
// };
//
// // Bitstream reader for entropy-coded data
// const BitstreamReader = struct {
//     data: []const u8,
//     pos: usize,
//     bit_buffer: u32,
//     bits_left: u5,
//
//     fn init(data: []const u8, start: usize) BitstreamReader {
//         return .{
//             .data = data,
//             .pos = start,
//             .bit_buffer = 0,
//             .bits_left = 0,
//         };
//     }
//
//     fn nextByte(self: *BitstreamReader) !u8 {
//         if (self.pos >= self.data.len) return DecodeError.UnexpectedEndOfData;
//         const b = self.data[self.pos];
//         self.pos += 1;
//         // Handle byte stuffing: 0xFF 0x00 → 0xFF
//         if (b == 0xFF) {
//             if (self.pos >= self.data.len) return DecodeError.UnexpectedEndOfData;
//             const next = self.data[self.pos];
//             if (next == 0x00) {
//                 self.pos += 1;
//                 return 0xFF;
//             } else if (next >= 0xD0 and next <= 0xD7) {
//                 // Restart marker — handled by caller
//                 return DecodeError.InvalidMarker;
//             } else {
//                 return DecodeError.InvalidData;
//             }
//         }
//         return b;
//     }
//
//     fn readBit(self: *BitstreamReader) !u1 {
//         if (self.bits_left == 0) {
//             const b = try self.nextByte();
//             self.bit_buffer = @intCast(b);
//             self.bits_left = 8;
//         }
//         self.bits_left -= 1;
//         return @intCast((self.bit_buffer >> self.bits_left) & 1);
//     }
//
//     fn readBits(self: *BitstreamReader, n: u5) !u16 {
//         if (n == 0) return 0;
//         var val: u16 = 0;
//         for (0..n) |_| {
//             val = (val << 1) | @as(u16, try self.readBit());
//         }
//         return val;
//     }
//
//     fn decodeHuffman(self: *BitstreamReader, table: *const HuffmanTable) !u8 {
//         var code: i32 = 0;
//         for (1..17) |length| {
//             const bit: i32 = @intCast(try self.readBit());
//             code = (code << 1) | bit;
//             if (code <= table.max_code[length]) {
//                 const idx = table.val_offset[length] + code - table.min_code[length];
//                 if (idx < 0 or idx >= table.num_values) return DecodeError.InvalidHuffmanCode;
//                 return table.values[@intCast(idx)];
//             }
//         }
//         return DecodeError.InvalidHuffmanCode;
//     }
//
//     fn alignToByte(self: *BitstreamReader) void {
//         self.bits_left = 0;
//     }
// };
//
// fn receiveExtend(bits: u16, category: u4) i16 {
//     if (category == 0) return 0;
//     const val: i16 = @intCast(bits);
//     const cat_minus_1: u4 = category - 1;
//     const threshold: i16 = @as(i16, 1) << cat_minus_1;
//     if (val < threshold) {
//         return val - (@as(i16, 1) << category) + 1;
//     }
//     return val;
// }
//
// fn buildHuffmanTable(lengths: []const u8, values: []const u8) HuffmanTable {
//     var table: HuffmanTable = .{
//         .min_code = [_]i32{0} ** 17,
//         .max_code = [_]i32{-1} ** 17,
//         .val_offset = [_]i32{0} ** 17,
//         .values = [_]u8{0} ** 256,
//         .num_values = 0,
//     };
//
//     // Copy values
//     const num_vals: u16 = @intCast(@min(values.len, 256));
//     for (0..num_vals) |i| {
//         table.values[i] = values[i];
//     }
//     table.num_values = num_vals;
//
//     // Build code tables
//     var code: i32 = 0;
//     var val_idx: i32 = 0;
//     for (1..17) |length| {
//         table.min_code[length] = code;
//         table.val_offset[length] = val_idx - code;
//         const count: i32 = @intCast(lengths[length - 1]);
//         if (count > 0) {
//             table.max_code[length] = code + count - 1;
//         } else {
//             table.max_code[length] = -1;
//         }
//         val_idx += count;
//         code = (code + count) << 1;
//     }
//
//     return table;
// }
//
// fn idct1d(input: *const [8]f64, output: *[8]f64) void {
//     for (0..8) |x| {
//         var sum: f64 = 0;
//         for (0..8) |u_idx| {
//             var cu: f64 = 1.0;
//             if (u_idx == 0) cu = inv_sqrt2;
//             sum += cu * input[u_idx] * idct_cosines[u_idx][x];
//         }
//         output[x] = sum * 0.5;
//     }
// }
//
// pub fn idct8x8(block: *[64]i16) void {
//     var temp: [64]f64 = undefined;
//
//     // Rows
//     for (0..8) |row| {
//         var input: [8]f64 = undefined;
//         for (0..8) |col| {
//             input[col] = @floatFromInt(block[row * 8 + col]);
//         }
//         var output: [8]f64 = undefined;
//         idct1d(&input, &output);
//         for (0..8) |col| {
//             temp[row * 8 + col] = output[col];
//         }
//     }
//
//     // Columns
//     for (0..8) |col| {
//         var input: [8]f64 = undefined;
//         for (0..8) |row| {
//             input[row] = temp[row * 8 + col];
//         }
//         var output: [8]f64 = undefined;
//         idct1d(&input, &output);
//         for (0..8) |row| {
//             // Level shift (+128) and clamp
//             const val = output[row] + 128.0;
//             const clamped = @max(0.0, @min(255.0, val));
//             block[row * 8 + col] = @intFromFloat(clamped);
//         }
//     }
// }
//
// pub fn ycbcrToRgb(y_val: u8, cb: u8, cr: u8) struct { r: u8, g: u8, b: u8 } {
//     const yf: f64 = @floatFromInt(y_val);
//     const cbf: f64 = @floatFromInt(cb);
//     const crf: f64 = @floatFromInt(cr);
//
//     const r = yf + 1.402 * (crf - 128.0);
//     const g = yf - 0.344136 * (cbf - 128.0) - 0.714136 * (crf - 128.0);
//     const b = yf + 1.772 * (cbf - 128.0);
//
//     return .{
//         .r = @intFromFloat(@max(0.0, @min(255.0, r))),
//         .g = @intFromFloat(@max(0.0, @min(255.0, g))),
//         .b = @intFromFloat(@max(0.0, @min(255.0, b))),
//     };
// }
//
// fn decode8x8Block(
//     reader: *BitstreamReader,
//     dc_table: *const HuffmanTable,
//     ac_table: *const HuffmanTable,
//     quant_table: *const [64]u16,
//     prev_dc: *i16,
// ) ![64]i16 {
//     var block = [_]i16{0} ** 64;
//
//     // DC coefficient
//     const dc_category = try reader.decodeHuffman(dc_table);
//     if (dc_category > 15) return DecodeError.InvalidData;
//     const dc_bits = try reader.readBits(@intCast(dc_category));
//     const dc_diff = receiveExtend(dc_bits, @intCast(dc_category));
//     prev_dc.* += dc_diff;
//     block[0] = prev_dc.*;
//
//     // AC coefficients
//     var idx: u8 = 1;
//     while (idx < 64) {
//         const symbol = try reader.decodeHuffman(ac_table);
//         if (symbol == 0x00) break; // EOB
//         const run = symbol >> 4;
//         const category: u4 = @intCast(symbol & 0x0F);
//         if (symbol == 0xF0) {
//             // ZRL — skip 16 zeros
//             idx += 16;
//             continue;
//         }
//         idx += run;
//         if (idx >= 64) break;
//         const ac_bits = try reader.readBits(@intCast(category));
//         block[idx] = receiveExtend(ac_bits, @intCast(category));
//         idx += 1;
//     }
//
//     // Dequantize and unzigzag
//     var result = [_]i16{0} ** 64;
//     for (0..64) |i| {
//         const dest = zigzag_map[i];
//         result[dest] = block[i] * @as(i16, @intCast(quant_table[i]));
//     }
//
//     return result;
// }
//
// pub fn decode(data: []const u8, allocator: std.mem.Allocator) !JpgImage {
//     if (data.len < 2) return DecodeError.InvalidSignature;
//     if (data[0] != 0xFF or data[1] != 0xD8) return DecodeError.InvalidSignature;
//
//     var quant_tables: [4][64]u16 = [_][64]u16{[_]u16{1} ** 64} ** 4;
//     var dc_tables: [4]HuffmanTable = undefined;
//     var ac_tables: [4]HuffmanTable = undefined;
//     var dc_table_valid = [_]bool{false} ** 4;
//     var ac_table_valid = [_]bool{false} ** 4;
//
//     var components: [4]Component = undefined;
//     var num_components: u8 = 0;
//     var width: u32 = 0;
//     var height: u32 = 0;
//     var precision: u8 = 0;
//
//     var restart_interval: u16 = 0;
//     var scan_components: [4]ScanComponent = undefined;
//     var num_scan_components: u8 = 0;
//
//     var pos: usize = 2;
//
//     // Marker parsing loop
//     while (pos + 1 < data.len) {
//         if (data[pos] != 0xFF) {
//             pos += 1;
//             continue;
//         }
//         const marker = data[pos + 1];
//         pos += 2;
//
//         switch (marker) {
//             0xD9 => break, // EOI
//             0x00, 0xFF => continue, // padding / stuffed byte
//             0xD0...0xD7 => continue, // restart markers (standalone)
//             else => {},
//         }
//
//         // Markers with length field
//         if (pos + 1 >= data.len) return DecodeError.UnexpectedEndOfData;
//         const seg_len = (@as(u16, data[pos]) << 8) | @as(u16, data[pos + 1]);
//         if (seg_len < 2 or pos + seg_len > data.len) return DecodeError.UnexpectedEndOfData;
//
//         const seg_data = data[pos + 2 .. pos + seg_len];
//         const next_pos = pos + seg_len;
//
//         switch (marker) {
//             // DQT
//             0xDB => {
//                 var dp: usize = 0;
//                 while (dp < seg_data.len) {
//                     const pq = seg_data[dp] >> 4; // precision: 0=8bit, 1=16bit
//                     const tq = seg_data[dp] & 0x0F; // table id
//                     dp += 1;
//                     if (tq >= 4) return DecodeError.InvalidData;
//                     for (0..64) |i| {
//                         if (pq == 0) {
//                             if (dp >= seg_data.len) return DecodeError.UnexpectedEndOfData;
//                             quant_tables[tq][i] = seg_data[dp];
//                             dp += 1;
//                         } else {
//                             if (dp + 1 >= seg_data.len) return DecodeError.UnexpectedEndOfData;
//                             quant_tables[tq][i] = (@as(u16, seg_data[dp]) << 8) | seg_data[dp + 1];
//                             dp += 2;
//                         }
//                     }
//                 }
//             },
//             // DHT
//             0xC4 => {
//                 var dp: usize = 0;
//                 while (dp < seg_data.len) {
//                     const tc = seg_data[dp] >> 4; // 0=DC, 1=AC
//                     const th = seg_data[dp] & 0x0F; // table id
//                     dp += 1;
//                     if (th >= 4) return DecodeError.InvalidData;
//                     if (dp + 16 > seg_data.len) return DecodeError.UnexpectedEndOfData;
//                     const lengths = seg_data[dp .. dp + 16];
//                     dp += 16;
//                     var total: usize = 0;
//                     for (lengths) |l| total += l;
//                     if (dp + total > seg_data.len) return DecodeError.UnexpectedEndOfData;
//                     const values = seg_data[dp .. dp + total];
//                     dp += total;
//
//                     if (tc == 0) {
//                         dc_tables[th] = buildHuffmanTable(lengths, values);
//                         dc_table_valid[th] = true;
//                     } else {
//                         ac_tables[th] = buildHuffmanTable(lengths, values);
//                         ac_table_valid[th] = true;
//                     }
//                 }
//             },
//             // SOF0 (baseline)
//             0xC0 => {
//                 if (seg_data.len < 6) return DecodeError.InvalidHeader;
//                 precision = seg_data[0];
//                 if (precision != 8) return DecodeError.UnsupportedFormat;
//                 height = (@as(u32, seg_data[1]) << 8) | seg_data[2];
//                 width = (@as(u32, seg_data[3]) << 8) | seg_data[4];
//                 num_components = seg_data[5];
//                 if (num_components != 1 and num_components != 3) return DecodeError.UnsupportedFormat;
//                 if (seg_data.len < 6 + @as(usize, num_components) * 3) return DecodeError.InvalidHeader;
//                 for (0..num_components) |i| {
//                     const offset = 6 + i * 3;
//                     components[i] = .{
//                         .id = seg_data[offset],
//                         .h_sampling = seg_data[offset + 1] >> 4,
//                         .v_sampling = seg_data[offset + 1] & 0x0F,
//                         .quant_table_id = seg_data[offset + 2],
//                     };
//                 }
//             },
//             // SOF2 (progressive) — reject
//             0xC2 => return DecodeError.UnsupportedFormat,
//             // DRI
//             0xDD => {
//                 if (seg_data.len < 2) return DecodeError.InvalidData;
//                 restart_interval = (@as(u16, seg_data[0]) << 8) | seg_data[1];
//             },
//             // SOS — start of scan, decode entropy data
//             0xDA => {
//                 if (seg_data.len < 1) return DecodeError.InvalidData;
//                 num_scan_components = seg_data[0];
//                 if (num_scan_components != num_components) return DecodeError.UnsupportedFormat;
//                 if (seg_data.len < 1 + @as(usize, num_scan_components) * 2 + 3) return DecodeError.InvalidData;
//
//                 for (0..num_scan_components) |i| {
//                     const offset = 1 + i * 2;
//                     const comp_id = seg_data[offset];
//                     const table_sel = seg_data[offset + 1];
//                     // Find component index by id
//                     var comp_idx: u8 = 0;
//                     for (0..num_components) |c| {
//                         if (components[c].id == comp_id) {
//                             comp_idx = @intCast(c);
//                             break;
//                         }
//                     }
//                     scan_components[i] = .{
//                         .component_idx = comp_idx,
//                         .dc_table_id = table_sel >> 4,
//                         .ac_table_id = table_sel & 0x0F,
//                     };
//                 }
//
//                 if (width == 0 or height == 0) return DecodeError.InvalidDimensions;
//
//                 // Determine MCU dimensions
//                 var max_h: u8 = 1;
//                 var max_v: u8 = 1;
//                 if (num_components == 3) {
//                     for (0..num_components) |i| {
//                         if (components[i].h_sampling > max_h) max_h = components[i].h_sampling;
//                         if (components[i].v_sampling > max_v) max_v = components[i].v_sampling;
//                     }
//                 }
//
//                 const mcu_width: u32 = @as(u32, max_h) * 8;
//                 const mcu_height: u32 = @as(u32, max_v) * 8;
//                 const mcus_x = (width + mcu_width - 1) / mcu_width;
//                 const mcus_y = (height + mcu_height - 1) / mcu_height;
//
//                 // Allocate output
//                 const pixel_len: usize = @as(usize, width) * @as(usize, height) * 3;
//                 const pixels = try allocator.alloc(u8, pixel_len);
//                 errdefer allocator.free(pixels);
//
//                 // Allocate component sample buffers for one MCU
//                 const mcu_samples_len = @as(usize, mcu_width) * @as(usize, mcu_height);
//                 var comp_samples: [4][]u8 = undefined;
//                 var comp_samples_allocated: u8 = 0;
//                 errdefer {
//                     for (0..comp_samples_allocated) |i| allocator.free(comp_samples[i]);
//                 }
//                 for (0..num_components) |i| {
//                     comp_samples[i] = try allocator.alloc(u8, mcu_samples_len);
//                     comp_samples_allocated = @intCast(i + 1);
//                 }
//                 defer {
//                     for (0..num_components) |i| allocator.free(comp_samples[i]);
//                 }
//
//                 var reader = BitstreamReader.init(data, next_pos);
//                 var prev_dc = [_]i16{0} ** 4;
//                 var mcu_count: u32 = 0;
//
//                 for (0..mcus_y) |mcu_row| {
//                     for (0..mcus_x) |mcu_col| {
//                         // Handle restart markers
//                         if (restart_interval > 0 and mcu_count > 0 and mcu_count % restart_interval == 0) {
//                             reader.alignToByte();
//                             // Skip to next restart marker
//                             while (reader.pos + 1 < reader.data.len) {
//                                 if (reader.data[reader.pos] == 0xFF) {
//                                     const rm = reader.data[reader.pos + 1];
//                                     if (rm >= 0xD0 and rm <= 0xD7) {
//                                         reader.pos += 2;
//                                         break;
//                                     }
//                                 }
//                                 reader.pos += 1;
//                             }
//                             prev_dc = [_]i16{0} ** 4;
//                         }
//
//                         // Decode each component's blocks in this MCU
//                         for (0..num_scan_components) |sc| {
//                             const comp_idx = scan_components[sc].component_idx;
//                             const dc_tid = scan_components[sc].dc_table_id;
//                             const ac_tid = scan_components[sc].ac_table_id;
//                             if (!dc_table_valid[dc_tid] or !ac_table_valid[ac_tid])
//                                 return DecodeError.InvalidData;
//                             const qt_id = components[comp_idx].quant_table_id;
//                             const h_samp = components[comp_idx].h_sampling;
//                             const v_samp = components[comp_idx].v_sampling;
//
//                             for (0..v_samp) |bv| {
//                                 for (0..h_samp) |bh| {
//                                     var block = try decode8x8Block(
//                                         &reader,
//                                         &dc_tables[dc_tid],
//                                         &ac_tables[ac_tid],
//                                         &quant_tables[qt_id],
//                                         &prev_dc[comp_idx],
//                                     );
//                                     idct8x8(&block);
//
//                                     // Store samples — upsample if needed
//                                     const scale_h = max_h / h_samp;
//                                     const scale_v = max_v / v_samp;
//
//                                     for (0..8) |by| {
//                                         for (0..8) |bx| {
//                                             const sample: u8 = @intCast(@as(u16, @bitCast(block[by * 8 + bx])));
//                                             // Nearest-neighbor upsample
//                                             for (0..scale_v) |sv| {
//                                                 for (0..scale_h) |sh| {
//                                                     const px = bh * 8 * scale_h + bx * scale_h + sh;
//                                                     const py = bv * 8 * scale_v + by * scale_v + sv;
//                                                     if (px < mcu_width and py < mcu_height) {
//                                                         comp_samples[comp_idx][py * mcu_width + px] = sample;
//                                                     }
//                                                 }
//                                             }
//                                         }
//                                     }
//                                 }
//                             }
//                         }
//
//                         // Write MCU to output pixels
//                         for (0..mcu_height) |py| {
//                             for (0..mcu_width) |px| {
//                                 const img_x = mcu_col * mcu_width + px;
//                                 const img_y = mcu_row * mcu_height + py;
//                                 if (img_x >= width or img_y >= height) continue;
//                                 const out_idx = (img_y * width + img_x) * 3;
//                                 const sample_idx = py * mcu_width + px;
//
//                                 if (num_components == 1) {
//                                     const y_val = comp_samples[0][sample_idx];
//                                     pixels[out_idx] = y_val;
//                                     pixels[out_idx + 1] = y_val;
//                                     pixels[out_idx + 2] = y_val;
//                                 } else {
//                                     const rgb = ycbcrToRgb(
//                                         comp_samples[0][sample_idx],
//                                         comp_samples[1][sample_idx],
//                                         comp_samples[2][sample_idx],
//                                     );
//                                     pixels[out_idx] = rgb.r;
//                                     pixels[out_idx + 1] = rgb.g;
//                                     pixels[out_idx + 2] = rgb.b;
//                                 }
//                             }
//                         }
//
//                         mcu_count += 1;
//                     }
//                 }
//
//                 return JpgImage{
//                     .header = .{
//                         .width = width,
//                         .height = height,
//                         .num_components = num_components,
//                         .precision = precision,
//                     },
//                     .pixels = pixels,
//                     .allocator = allocator,
//                 };
//             },
//             // Skip APPn, COM, and everything else
//             else => {},
//         }
//
//         pos = next_pos;
//     }
//
//     return DecodeError.UnexpectedEndOfData;
// }
//
// pub fn loadFromFile(filepath: []const u8, allocator: std.mem.Allocator) !JpgImage {
//     const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
//     defer file.close();
//
//     const stat = try file.stat();
//     const file_data = try allocator.alloc(u8, stat.size);
//     defer allocator.free(file_data);
//
//     const bytes_read = try file.readAll(file_data);
//     if (bytes_read != stat.size) return DecodeError.UnexpectedEndOfData;
//
//     return decode(file_data, allocator);
// }
//
// // ─── Unit Tests ─────────────────────────────────────────────────────────
//
// test "decode valid JPG file from disk" {
//     const allocator = testing.allocator;
//     var image = try loadFromFile("src/Images/BasicArt.jpg", allocator);
//     defer image.deinit();
//
//     try testing.expect(image.header.width > 0);
//     try testing.expect(image.header.height > 0);
//     try testing.expect(image.header.precision == 8);
//
//     const expected_len = @as(usize, image.header.width) *
//         @as(usize, image.header.height) * 3;
//     try testing.expectEqual(expected_len, image.pixels.len);
// }
//
// test "reject invalid signature" {
//     const allocator = testing.allocator;
//     var bad = [_]u8{0} ** 64;
//     bad[0] = 'X';
//     bad[1] = 'Y';
//     const result = decode(&bad, allocator);
//     try testing.expectError(DecodeError.InvalidSignature, result);
// }
//
// test "reject truncated data" {
//     const allocator = testing.allocator;
//     const short = [_]u8{ 0xFF, 0xD8 };
//     const result = decode(&short, allocator);
//     try testing.expectError(DecodeError.UnexpectedEndOfData, result);
// }
//
// test "ycbcrToRgb pure white" {
//     const rgb = ycbcrToRgb(255, 128, 128);
//     try testing.expectEqual(@as(u8, 255), rgb.r);
//     try testing.expectEqual(@as(u8, 255), rgb.g);
//     try testing.expectEqual(@as(u8, 255), rgb.b);
// }
//
// test "ycbcrToRgb pure black" {
//     const rgb = ycbcrToRgb(0, 128, 128);
//     try testing.expectEqual(@as(u8, 0), rgb.r);
//     try testing.expectEqual(@as(u8, 0), rgb.g);
//     try testing.expectEqual(@as(u8, 0), rgb.b);
// }
//
// test "zigzag_map covers all 64 positions" {
//     var seen = [_]bool{false} ** 64;
//     for (zigzag_map) |pos_val| {
//         try testing.expect(pos_val < 64);
//         seen[pos_val] = true;
//     }
//     for (seen) |s| {
//         try testing.expect(s);
//     }
// }
//
// test "receiveExtend positive and negative" {
//     // category=3, bits=5 (101): threshold=4, val=5>=4 → positive → 5
//     try testing.expectEqual(@as(i16, 5), receiveExtend(5, 3));
//     // category=3, bits=2 (010): threshold=4, val=2<4 → negative → 2 - 8 + 1 = -5
//     try testing.expectEqual(@as(i16, -5), receiveExtend(2, 3));
//     // category=1, bits=1: threshold=1, val=1>=1 → 1
//     try testing.expectEqual(@as(i16, 1), receiveExtend(1, 1));
//     // category=1, bits=0: threshold=1, val=0<1 → 0-2+1 = -1
//     try testing.expectEqual(@as(i16, -1), receiveExtend(0, 1));
//     // category=0: always 0
//     try testing.expectEqual(@as(i16, 0), receiveExtend(0, 0));
// }
//
// test "idct8x8 all-zero block produces 128" {
//     var block = [_]i16{0} ** 64;
//     idct8x8(&block);
//     for (block) |val| {
//         try testing.expectEqual(@as(i16, 128), val);
//     }
// }
//
// test "idct8x8 DC-only block produces uniform output" {
//     var block = [_]i16{0} ** 64;
//     block[0] = 100; // DC coefficient
//     idct8x8(&block);
//     // All values should be the same (DC produces uniform offset)
//     const expected = block[0];
//     for (block) |val| {
//         try testing.expectEqual(expected, val);
//     }
// }
