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

const ChunkHeader = struct {
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
            .unknown => |u| w.print("Unknown: {s}: {d}\n", .{ u, self.len }),
            inline else => w.print("{t}: {d}\n", .{ self.type, self.len }),
        };
    }
};

const IHDR = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: Compression,
    filter_method: u8,
    interlace_method: u8,
};

fn discardCrc(r: *std.Io.Reader) !void {
    try r.discardAll(4);
}

pub fn readPng(r: *std.Io.Reader) !void {
    const sig = try r.take(8);
    if (!std.mem.eql(u8, sig, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        return DecodeError.InvalidSignature;

    var iter: usize = 0;
    while (true) : (iter += 1) {
        const chunk = try ChunkHeader.read(r);
        if (iter == 0) {
            try switch (chunk.type) {
                .IHDR => {},
                else => DecodeError.InvalidChunk,
            };
        }
        std.debug.print("{f}\n", .{chunk});
        try r.discardAll(chunk.len);
        // TODO: Perform CRC
        try discardCrc(r);

        if (chunk.type == .IEND) break;
    }
}
