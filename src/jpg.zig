const std = @import("std");
// Joint Photographic Export Group (JPEG)
// 1. parse markers
// SOI, SOF0, DQT, DHT, SOS, EOI
// 2. Read quantization tables
// 3. read huffman table
// 4. decode MCUs (minimum coded units)
//  - huffmand decode DC/AC coefficients
//  - dequantize
//  - perform 8x8 IDCT
// 5. Upsample chroma (if subsampled)
// 6. Convert YCbCR -> RGB

// Encode:
// 1. Color space conversion
//  - rgb component per pixel, [0, 255], creates color
//  - Y = Luminance = 0.299 R + 0.587 G + 0.144 B
//  - Cb = Blue Chrominance = -0.1687 R - 0.3313 G + 0.5 B + 128
//  - Cr = Red Chrominance = 0.5 R - 0.4187 G - 0.0813 B + 128
//  - reversible
// 2. Chrominance Downsampling
//  - eyes bad at chrominance, good at luminance
//  - split data into Cb + Cr
//  - take 2x2 blocks of pixels + round to integer
//  - compute avg value per block
//  - shrink image so each avg value of 4 px block takes single pixel
//  - Cb/Cr = 1/4th original size, luminance = same size
//  - image = 1/2 original size
//  - slightly removes information (rounding)
// 3. Discrete Cosine Transform
//  - loop over luminance, blue chrominance, and red chrominance
//  - divide data into 8x8 pixels = block = 64 pixels [0-255]
//  - subtract 128 from each value in block
//  - use 64 based images from signal analysis = rebuild any combo of images from this
//  - add all base images * constants = recreate image
//  - does not compress/shrink image = information preserver
// 4. Quantization
// - removes information
// - eyes are not good at high frequency information = its ok
//  - good = strong edges
//  - bad = single blades of grass, blur of background sky, flowers, high freq. info
// - divide table of constants by quantization table -> round to closest integer
//   - loses info
// - higher #'s in bottom right = details eyes can't resolve
// - smaller #'s in top left = distinct patterns
// - throw away values in chrominance quantization table that are higher than luminance quantization table (not visible details)
// - total data: 64 base images, chrominance quant table (2x), luminance quant table (1x)
// 5. Run Length Encoding / Huffman Encoding
// - list of numbers for 1 block of luminance
//  - use zig-zag pattern, more likely non-zero values are in top-left
//  - use run length encoding
//  - use huffman encoding scheme

// In Summary:
// 1. Chroma subsampling: RGB -> YCbCr (4:2:2)
// - reduces color planes by 1/2 size = 1/4 required data
// 2. For each 8x8 block = discrete cosine transform
// 3. Quantization Table = remove higher frequency patterns
// 4. RLE + Huffman Encoding

// H264 = uses similar algorithms to jpg
// uses I-frame = similar to jpg but for 1 out of every 30 frames - then interpolates between
// frames: I-frame, Predicted Frame, Bidirectional Predicted Frame

// Optimizations:
// 1. store zig zag + undo zig zag
// 2. perform rle using vectors instead (bit comparisons)

// Decode
// 5. Huffman Decoding / Run Length Decoding
// - undo huffman
// - undo rle = 8x8 blocks
// 4. Quantization
// - sample Cb + Cr + Y and undo to get close to original pixel
// - luminance changes pixel to pixel = recalculated pixel changes
// - multiply 8x8 blocks by quantization table = output
// 3. Discrete Cosine Transform
// - multiply output by base images
// - add constituent images together
// 2. Chrominance Upsampling
// - upsample red + blue chrominance images
// 1. Color Space
// - convert chrominance values back to rgb values

// Goal:
// 4 blocks of luminance (8x8x4) + 1 Cb block (8x8) + 1 Cr block (8x8) = 16x16 block
// nearly identical to uncompressed image

// Shortcomings:
// 1. Quality Scale
// - decrease scale = increase # of 0s in quant tables = more lost info + more compression
// - reduces precision to image block + more to high freq data
// - jpg = good for nature, camera resolution problems + smooth textures = easier
// - bad at vector graphics = bad at straight lines

// pub const Jpeg = struct {
//     allo: std.mem.Allocator,
//
//     pub fn init(allo: std.mem.Allocator) Jpeg {
//         return .{ .allo = allo };
//     }
//
//     pub fn decode(self: *@This(), data: []const u8) !Image {
//         var stream = Stream.init(data);
//         try stream.expectMarker(0xFFD8); // SOI
//         while (true) {
//             const marker = try stream.nextMarker();
//             switch (marker) {
//                 0xFFC0 => try self.parseSOF0(&stream),
//                 0xFFDB => try self.parseDQT(&stream),
//                 0xFFC4 => try self.parseDHT(&stream),
//                 0xFFDA => return try self.parseSOS(&stream),
//                 0xFFD9 => return error.UnexpectedEOI,
//                 else => try stream.skipMarker(),
//             }
//         }
//     }
//
//     fn parseDQT(self: *@This(), stream: *Stream) !void {
//         // quantization
//         const len = try stream.readBEu16();
//         var remaining = len - 2;
//
//         while (remaining > 0) {
//             const info = try stream.readByte();
//             const table_id = info & 0x0F;
//
//             var qt: [64]u16 = undefined;
//             for (qt) |*v| v.* = try stream.readBEu16();
//
//             self.quant_tables[table_id] = qt;
//             remamining -= 1 + 64 * 2;
//         }
//     }
//
//     fn parseDHT(self: *@This(), stream: *Stream) !void {
//         const len = try stream.readBEu16();
//         var remaining = len - 2;
//
//         while (remaining > 0) {
//             const info = try stream.readByte();
//             const table_class = info >> 4; // 0 = DC, 1 = AC
//             const table_id = info & 0x0F;
//
//             var counts: [16]u8 = undefined;
//             try stream.readInto(&counts);
//
//             var total: usize = 0;
//             for (counts) |c| total += c;
//
//             const values = try self.allo.alloc(u8, total);
//             try stream.readInto(values);
//
//             self.huff_tables[table_class][table_id] = try HuffmanTable.build(counts, values);
//
//             remaining -= 1 + 16 + total;
//         }
//     }
// };
//
// const BitReader = struct {
//     data: []const u8,
//     pos: usize = 0,
//     bit_buffer: u32 = 0,
//     bits: u8 = 0,
//
//     fn getBit(self: *@This()) !bool {
//         if (self.bits == 0) {
//             self.bit_buffer = self.data[self.pos];
//             self.pos += 1;
//             self.bits = 0;
//         }
//         self.bits -= 1;
//         return @intCast((self.bit_buffer >> self.bits) & 1);
//     }
//
//     fn decodeHuffman(self: *@This(), table: *const HuffmanTable) !u16 {
//         var code: u16 = 0;
//         var len: u8 = 0;
//
//         while (len < 16) {
//             code = (code << 1) | try self.getBit();
//             len += 1;
//             if (table.lookup[len][code]) |v| return v;
//         }
//         return error.InvalidHuffmanCode;
//     }
//
//     fn decodeBlock(
//         self: *@This(),
//         dc_table: *const HuffmanTable,
//         ac_table: *const HuffmanTable,
//         prev_dc: *i32,
//         out: *[64]i32,
//     ) !void {
//         // DC
//         const dc_len = try self.decodeHuffman(dc_table);
//         const dc_diff = try self.receiveExtend(dc_len);
//         prev_dc.* += dc_diff;
//         out[0] = prev_dc.*;
//
//         // AC
//         var i: usize = 1;
//         while (i < 64) {
//             const sym = try self.decodeHuffmann(ac_table);
//             if (sym == 0) break; // EOB
//
//             const run = sym >> 4;
//             const size = sym & 0x0F;
//
//             i += run;
//             if (i >= 64) break;
//
//             out[i] = try self.receiveExtend(size);
//             i += 1;
//         }
//     }
// };
//
// fn dequantize(block: *[64]i32, qt: *const [64]u16) void {
//     for (block, 0..) |*v, i| v.* *= qt[i];
// }

// 1. compute frequency of each character
// 2. order unique characters by frequency (least to most)
// 3. take least two, add together + add new node with this sum above them - add new sum into list wherever it sits higher up
// 4. repeat 1-3 until 1 node left
// - left fork = 0, right fork = 1, decompress/recompress this way
// - mathematically best way to compress single characters, unless you increase # of characters

// better encodings:
// try both below for speed
// arithmetic coding = patents expired = supported by jpeg
// ANS = arithmetic numeral systems

const std = @import("std");

jfif: i32 = 0,
app14_color_transform: App14ColorTransform = .none,
marker: Marker = .none,

pub fn readFile(allo: std.mem.Allocator, filename: []const u8) !std.fs.File {
    var file = try std.fs.openFileAbsolute(filename, .{ .mode = .read_only });
    defer file.close();
}

const Channels = enum {
    default = 0,
    grey = 1,
    grey_alpha = 2,
    rgb = 3,
    rgb_alpha = 4,
};

const App14ColorTransform = enum {
    null = -1,
    none = 0,
    one = 1,
    two = 2,
};

const Marker = enum {
    none,
};

fn getMarker(j: @This()) Marker {
    switch (j.marker) {
        .none => {},
        else => {
            x = j.marker;
            j.marker = .none;
            return x;
        },
    }
    x = get8(j.s);
    if (x != 0xFF) return .none;
    while (x == 0xFF) {
        x = get8(j.s);
    }
    return x;
}
