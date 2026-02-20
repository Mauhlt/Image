const std = @import("std");
const testing = std.testing;
const DecodeError = @import("Error.zig").DecodeError;
const isSigSame = @import("Misc.zig").isSigSame;

pub fn readPng(r: *std.Io.Reader) !void {
    const sig: []const u8 = try r.take(8);
    const exp_sig: []const u8 = &.{ 137, 80, 78, 71, 13, 10, 26, 10 };
    try isSigSame(sig, exp_sig);

    const hdr = try Chunk.read(r);
    std.debug.print("{f}\n", .{hdr});
    try r.discardAll(hdr.len);
    try discardCrc(r);

    while (true) {
        const chunk = try Chunk.read(r);
        std.debug.print("{f}\n", .{chunk});
        try r.discardAll(chunk.len);
        try discardCrc(r);

        if (chunk.type == .IEND) break;
    }
}

const Chunk = struct {
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
    // pHYS,
    // iTXt
    // IDAT,
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
        const chunk = try Chunk.read(reader);
        try reader.discardAll(chunk.len);
        try discardCrc(reader);
        try testing.expect(expected_chunk_types[i] == chunk.type);
        switch (chunk.type) {
            .unknown => |data| try testing.expectEqualStrings(expected_chunk_types.unknown, data),
            else => {},
        }
    }
    const chunk = try Chunk.read(reader);
    try testing.expect(expected_chunk_types[expected_chunk_types.len - 1] == chunk.type);
}
