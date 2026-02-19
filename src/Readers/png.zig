const std = @import("std");

/// Png Structure:
/// IHDR
/// IDAT
/// IEND
const DecodeError = error{
    InvalidSignature,
    InvalidChunk,
    StreamTooLong,
};

const PngHdrError = error{
    InvalidHdrType,
    InvalidHdrLen,
    UnsupportedCompression,
    UnsupportedColorType,
    InvalidBitDepth,
};

const ChunkTypes = union(enum) {
    IHDR,
    // sRGB,
    // gAMA,
    // pHYs,
    // ITxt,
    IDAT,
    IEND,
    unknown: [4]u8, // if you don't know, you can look at chunk name
};
const ChunkHdr = struct {
    len: u32 = 0,
    type: ChunkTypes,

    pub fn read(r: *std.Io.Reader) !@This() {
        // network byte order
        const len = try r.takeInt(u32, .big);
        if (len > (@as(u32, 1) << 31))
            return DecodeError.StreamTooLong;
        // identify type
        const type_str = try r.takeArray(4);

        const ChunkTypeEnums = @typeInfo(ChunkTypes).@"union".tag_type.?;
        const chunk_type_enum: ChunkTypeEnums = std.meta.stringToEnum(ChunkTypeEnums, type_str) orelse .unknown;

        return .{
            .len = len,
            .type = switch (chunk_type_enum) {
                .unknown => .{ .unknown = type_str[0..4].* },
                inline else => |t| t,
            },
        };
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        return switch (self.type) {
            .unknown => |u| w.print("{s}?: {d}\n", .{ u, self.len }),
            inline else => w.print("{t}: {d}\n", .{ self.type, self.len }),
        };
    }
};

const ColorType = enum(u8) {
    grayscale = 0, // allows 1, 2, 4, 8, 16 bit depths
    rgb = 2, // allows 8, 16 bit depths
    palette_index = 3, // must be preceded by palette chunk, allows 1, 2, 4, 8 bit depths
    grayscale_alpha = 4, // allows 8, 16 bit depths
    rgba = 6, // allows 8, 16 bit depths
};

const Compression = enum(u8) {
    base = 0, // deflate datastreams stored in zlib format
    unsupported,
};

const Filter = enum(u8) {
    scanline = 0,
};

const Interlace = enum(u8) {};

const PngHdr = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,

    pub fn read(r: *std.Io.Reader) !@This() {
        // chunk
        const chunk = try ChunkHdr.read(r);
        // error checks
        switch (chunk.type) {
            .IHDR => {},
            else => return PngHdrError.InvalidHdrType,
        }
        const exp_hdr_len = 13;
        if (chunk.len != exp_hdr_len) return PngHdrError.InvalidHdrLen;
        // get data
        const data = try r.take(exp_hdr_len);
        // construct hdr
        const hdr: @This() = .{
            .width = @as(u32, @bitCast(data[0..4].*)),
            .height = @as(u32, @bitCast(data[4..8].*)),
            .bit_depth = data[8],
            .color_type = @enumFromInt(data[9]),
            .compression_method = data[10], // @enumFromInt(data[10]),
            .filter_method = data[11], // @enumFromInt(data[11]),
            .interlace_method = data[12], // @enumFromInt(data[12]),
        };
        // discard crc
        try discardCrc(r);

        return hdr;
    }

    pub fn validate(self: *const @This()) !void {
        switch (self.compression_method) {
            .base => {},
            else => return PngHdrError.UnsupportedCompressionMethod,
        }
        switch (self.color_type) {
            .rgba => {},
            else => return PngHdrError.UnsupportedColorType,
        }
        switch (self.bit_depth) {
            8, 16 => {},
            else => return PngHdrError.InvalidBitDepth,
        }

        // // sample depth = bit depth except for rgb, then its always 8
        // switch (self.color_type) {
        //     .grayscale => {
        //         switch (self.bit_depth) {
        //             1, 2, 4, 8, 16 => {},
        //             else => return PngHdrError.InvalidBitDepth,
        //         }
        //     },
        //     .rgb => {
        //         switch (self.bit_depth) {
        //             8, 16 => {},
        //             else => return PngHdrError.InvalidBitDepth,
        //         }
        //         // sample depth is always 8
        //     },
        //     .palette_index => {
        //         switch (self.bit_depth) {
        //             1, 2, 4, 8 => {},
        //             else => return PngHdrError.InvalidBitDepth,
        //         }
        //     },
        //     .grayscale_alpha => {
        //         switch (self.bit_depth) {
        //             8, 16 => {},
        //             else => return PngHdrError.InvalidBitDepth,
        //         }
        //     },
        //     .rgba => {
        //         switch (self.bit_depth) {
        //             8, 16 => {},
        //             else => return PngHdrError.InvalidBitDepth,
        //         }
        //     },
        // }
    }
};

fn discardCrc(r: *std.Io.Reader) !void {
    try r.discardAll(4);
}

const Image = struct {
    width: u32,
    bit_depth: u8,
    data: []const u8,

    fn calcHeight(self: *const @This()) u32 {
        return self.data.len / self.width / (self.bit_depth / 8);
    }
};

const ConstImage = struct {};

pub fn readPng(allo: std.mem.Allocator, reader: *std.Io.Reader) !Image {
    const sig = try reader.take(8);
    if (!std.mem.eql(u8, sig, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        return DecodeError.InvalidSignature;

    const hdr = try PngHdr.read(reader);
    std.debug.print("PNG Hdr: {any}\n", .{hdr});
    try hdr.validate();

    std.debug.assert(hdr.color_type == .rgba);
    std.debug.assert(@mod(hdr.bit_depth, 8) == 0);
    const pixel_size = 4 * hdr.bit_depth / 8;

    const data = try allo.alloc(u8, hdr.width * hdr.height * pixel_size);
    var data_builder: std.ArrayList(u8) = .initBuffer(&data);

    var seen_idat: bool = false;

    while (true) {
        const chunk = try ChunkHdr.read(reader);
        std.debug.print("{f}\n", .{chunk});

        switch (chunk.type) {
            .IDAT => {
                if (seen_idat) return error.UnhandledMultiIdat;
                seen_idat = true;

                var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var decompressor: std.compress.flate.Decompress =
                    .init(reader, .zlib, &decompress_buf);

                const width_size = hdr.width * pixel_size;
                const scanline_size = width_size + 1;

                // TODO: Decompressed data len == chunk header len
                // Limited reader requires an extra buffer.
                for (0..hdr.height) |i| {
                    const scanline_filter = try decompressor.reader.takeByte();
                    _ = scanline_filter;
                    try decompressor.reader.readSliceAll(data[i * width_size ..][0..width_size]);
                    _ = try decompressor.reader.take(scanline_size);
                }
            },
            else => try reader.discardAll(chunk.len),
        }
        // TODO: Perform CRC
        try discardCrc(reader);
        if (chunk.type == .IEND) break;
    }

    return .{
        .width = hdr.width,
        .bit_depth = hdr.bit_depth,
        .data = data,
    };
}
