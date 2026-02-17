const std = @import("std");

const DecodeError = error{
    InvalidSignature,
};

const ChunkHeader = struct {
    len: u32,
    typ: [4]u8,

    pub fn read(r: *std.Io.Reader) !ChunkHeader {
        return .{
            .len = try r.takeInt(u32, .big),
            .type = (try r.takeArray(4)).*,
        };
    }

    pub fn format(self: @This(), w: *std.Io.Writer) !void {
        w.writeAll();
    }
};

pub fn readPng(r: *std.Io.Reader) !void {
    const sig = try r.take(8);
    if (!std.mem.eql(u8, sig, &.{ 137, 80, 78, 71, 13, 10, 26, 10 }))
        return DecodeError.InvalidSignature;

    const chunk = try ChunkHeader.read(r);
    std.debug.print("First Chunk: {any}\n", .{chunk});
}
