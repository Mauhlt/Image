const std = @import("std");
const DecodeError = @import("Error.zig").DecodeError;

pub fn readPng(r: *std.Io.Reader) !void {
    const sig = try r.take(8);
    const expected_sig = &.{ 137, 80, 78, 71, 13, 10, 26, 10 };
    if (std.mem.eql(u8, sig, expected_sig))
        return DecodeError.UnexpectedSignature;

    const chunk = try Chunk.read(r);
    std.debug.print("{f}\n", .{chunk});
}

const Chunk = struct {
    len: u32,
    type: PngType,

    pub fn read(r: *std.Io.Reader) !@This() {
        const chunk_len = try r.takeInt(u32, .big);
        const chunk_type_str = try r.takeArray(4);
        const chunk_type = std.meta.stringToEnum(PngType, try r.takeArray(4)) orelse
            return DecodeError.InvalidChunkType;

        return .{
            .len = chunk_len,
            .type = switch (chunk_type) {
                .unknown => .{ .unknown = chunk_type_str },
                else => |t| t,
            },
        };
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        return w.print("({t}: {d})\n", .{ self.type, self.len });
    }
};

const PngType = union(enum) {
    unknown: []const u8,
    IHDR,
    // IDAT,
    IEND,
};

fn discardCrc(r: *std.Io.Reader) !void {
    return r.discardAll(4);
}
