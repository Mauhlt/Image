const std = @import("std");
const testing = std.testing;
const DecodeError = @import("Error.zig").DecodeError;
const isSigSame = @import("Misc.zig").isSigSame;

const PngError = error{
    UnsupportedCompressionMethod,
    UnsupportedColorType,
    UnhandledMultiIdat,
};

pub fn readPng(r: *std.Io.Reader) !void {
    const sig: []const u8 = try r.take(8);
    const exp_sig: []const u8 = &.{ 137, 80, 78, 71, 13, 10, 26, 10 };
    try isSigSame(sig, exp_sig);

    const hdr = PngHeader.read(r);
    try hdr.validate();
    std.debug.print("Hdr: {any}\n", .{hdr});

    while (true) {
        const chunk = try ChunkHeader.read(r);
        std.debug.print("{f}\n", .{chunk});

        var seen_idat: bool = false;
        switch (chunk.type) {
            .IDAT => {
                if (seen_idat) return PngError.UnhandledMultiIdat;
                seen_idat = true;

                var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
                var decompressor = std.compress.flate.Decompress.init(r, .zlib, &decompress_buffer);
                decompressor.reader.take();
            },
            else => try r.discardAll(chunk.len),
        }

        try discardCrc(r);

        if (chunk.type == .IEND) break;
    }
}

const ChunkHeader = struct {
    len: u32,
    type: ChunkTypes,

    pub fn read(r: *std.Io.Reader) !@This() {
        const chunk_len = try r.takeInt(u32, .big);
        const chunk_type_str = try r.take(4);

        const ChunkTypeEnums = @typeInfo(ChunkTypes).@"union".tag_type.?;
        std.debug.print("Chunk Type Str: {s}\n", .{chunk_type_str});

        const chunk_type = std.meta.stringToEnum(ChunkTypeEnums, chunk_type_str) orelse .unknown;

        return .{
            .len = chunk_len,
            .type = switch (chunk_type) {
                .unknown => .{ .unknown = chunk_type_str[0..4].* },
                inline else => |t| t,
            },
        };
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        return switch (self.type) {
            .unknown => |t| w.print("{s}?: {d}\n", .{ t, self.len }),
            else => w.print("{t}: {d}\n", .{ self.type, self.len }),
        };
    }
};

const ChunkTypes = union(enum) {
    unknown: [4]u8,
    IHDR,
    // sRGB
    // gAMA
    // pHYS, // intended pixel size/aspect ratio, x: 4 bytes, y: 4 bytes, specifier: 1 byte
    // iTXt
    IDAT,
    IEND,
};

fn discardCrc(r: *std.Io.Reader) !void {
    return r.discardAll(4);
}

test "Parse Chunks" {
    const filepath: []const u8 = "src/Data/BasicArt.png";
    if (filepath.len == 0) return error.InvalidFilepath;

    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(&read_buffer);

    const expected_chunk_types = [_]ChunkTypes{
        .IHDR,
        .{ .unknown = "sRGB" },
        .{ .unknown = "gAMA" },
        .{ .unknown = "pHYs" },
        .{ .unknown = "iTXt" },
        .{ .unknown = "iDAT" },
        .IEND,
    };

    for (0..expected_chunk_types.len - 1) |i| {
        const chunk = try ChunkHeader.read(reader);
        try reader.discardAll(chunk.len);
        try discardCrc(reader);
        try testing.expect(expected_chunk_types[i] == chunk.type);
        switch (chunk.type) {
            .unknown => |data| try testing.expectEqualStrings(expected_chunk_types.unknown, data),
            else => {},
        }
    }
    const chunk = try ChunkHeader.read(reader);
    try testing.expect(expected_chunk_types[expected_chunk_types.len - 1] == chunk.type);
}

const PngHeader = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: u8,
    compression_method: u8,
    filter_method: u8,
    interlace_method: u8,

    pub fn read(r: *std.Io.Reader) !@This() {
        const chunk = try ChunkHeader.read(r);
        if (chunk.type != .IHDR) return DecodeError.ChunkIsNotHeader;
        if (chunk.len != 13) return DecodeError.InvalidHeaderLength;

        const result: @This() = .{
            .width = try r.takeInt(u32, .big),
            .height = try r.takeInt(u32, .big),
            .bit_depth = try r.takeByte(),
            .color_type = try r.takeByte(),
            .compression_method = try r.takeByte(),
            .filter_method = try r.takeByte(),
            .interlace_method = try r.takeByte(),
        };

        try discardCrc(r);
        return result;
    }

    pub fn validate(self: *const @This()) !void {
        if (self.compression_method != 0)
            return PngError.UnsupportedCompressionMethod;
        if (self.color_type != 6)
            return PngError.UnsupportedColorType;
    }
};

const ColorType = enum(u8) {
    grayscale = 0, // 1, 2, 4, 8, 16
    rgb = 2, // 8, 16
    palette = 3, // 1, 2, 4, 8
    grayscale_alpha = 4, // 8, 16
    rgba = 6, // 8, 16
};
