const std = @import("std");
const Image = @import("Image.zig");
const ConstImage = @import("ConstImage.zig");

pub fn readPng(r: *std.Io.Reader) !void {
    const sig = try r.take(8);
    const expected_sig = [_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (!std.mem.eql(u8, sig, &expected_sig))
        return error.UnsupportedSignature;

    const chunk = try readChunk(r);
    _ = chunk;
}

const ChunkType = union(enum) {
    IHDR,
    // IDAT,
    IEND,
    unknown: [4]u8,
};

fn readChunk(r: *std.Io.Reader) !void {
    const chunk_hdr = try Chunk.read(r);
    std.debug.print("Hdr: {f}\n", .{chunk_hdr});

    var i: usize = 0;
    while (true) : (i += 1) {
        const chunk = try Chunk.read(r);
        switch (chunk.type) {
            .IHDR => return error.MultiHdrUnsupported,
            .IEND => break,
            else => |t| std.debug.print("{t}\n", .{t}),
        }
        try r.discardAll(chunk.len);
        if (i > 10) break;
    }
}

fn discardCrc(r: *std.Io.Reader) !void {
    // 4 bytes used to check for corruption of data
    try r.discardAll(4);
}

const Chunk = struct {
    len: u32,
    type: ChunkType,

    pub fn read(r: *std.Io.Reader) !@This() {
        const chunk_len = try r.takeInt(u32, .big);
        const chunk_type_str = try r.takeArray(4); // hex values: 41:4A, 61:7A
        try discardCrc(r);

        if (chunk_len > ((@as(u32, 1) << 30) - 1))
            return error.UnsupportedChunkLen;

        const ChunkTypeEnums = @typeInfo(ChunkType).@"union".tag_type.?;
        const chunk_type = std.meta.stringToEnum(ChunkTypeEnums, chunk_type_str) orelse
            .unknown;

        return .{
            .len = chunk_len,
            .type = switch (chunk_type) {
                .unknown => .{ .unknown = chunk_type_str.* },
                inline else => |t| t,
            },
        };
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        return switch (self.type) {
            .IHDR => w.print("{t}: {d}\n", .{ self.type, self.len }),
            else => |t| w.print("{t}?: {d}\n", .{ t, self.len }),
        };
    }
};
