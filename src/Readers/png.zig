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
};

const ChunkTypes = union(enum) {
    IHDR,
    // sRGB,
    // gAMA,
    // pHYs,
    // ITxt,
    // IDAT,
    IEND,
    unknown: [4]u8, // if you don't know, you can look at chunk name
};

const Compression = enum(u8) {};
const Filter = enum(u8) {};
const Interlace = enum(u8) {};

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

const PngHdr = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
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
            .color_type = data[9],
            .compression_method = data[10], // @enumFromInt(data[10]),
            .filter_method = data[11], // @enumFromInt(data[11]),
            .interlace_method = data[12], // @enumFromInt(data[12]),
        };
        // discard crc
        try discardCrc(r);

        return hdr;
    }
};

fn discardCrc(r: *std.Io.Reader) !void {
    try r.discardAll(4);
}

pub fn readPng(r: *std.Io.Reader) !void {
    const sig = try r.take(8);
    if (!std.mem.eql(u8, sig, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        return DecodeError.InvalidSignature;

    const hdr = try PngHdr.read(r);
    std.debug.print("PNG Hdr: {any}\n", .{hdr});

    while (true) {
        const chunk = try ChunkHdr.read(r);
        std.debug.print("{f}\n", .{chunk});
        try r.discardAll(chunk.len);
        // TODO: Perform CRC
        try discardCrc(r);

        if (chunk.type == .IEND) break;
    }
}
