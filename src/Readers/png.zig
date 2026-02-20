const std = @import("std");
const DecodeError = @import("Error.zig").DecodeError;
const isSigSame = @import("Misc.zig").isSigSame;

pub fn readPng(r: *std.Io.Reader) !void {
    const sig: []const u8 = try r.take(8);
    const exp_sig: []const u8 = &.{ 137, 80, 78, 71, 13, 10, 26, 10 };
    try isSigSame(sig, exp_sig);

    const chunk = try Chunk.read(r);
    std.debug.print("{f}\n", .{chunk});
}

const Chunk = struct {
    len: u32,
    type: ChunkTypes,

    pub fn read(r: *std.Io.Reader) !@This() {
        const chunk_len = try r.takeInt(u32, .big);
        const chunk_type_str = try r.takeArray(4);

        const ChunkTypeEnums = @typeInfo(ChunkTypes).@"union".tag_type.?;
        std.debug.print("Chunk Type Str: {s}\n", .{chunk_type_str});

        const chunk_type = std.meta.stringToEnum(ChunkTypeEnums, chunk_type_str) orelse
            return DecodeError.InvalidChunkType;

        return .{
            .len = chunk_len,
            .type = switch (chunk_type) {
                .unknown => .{ .unknown = chunk_type_str },
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
    unknown: []const u8,
    IHDR,
    // IDAT,
    IEND,
};

fn discardCrc(r: *std.Io.Reader) !void {
    return r.discardAll(4);
}
