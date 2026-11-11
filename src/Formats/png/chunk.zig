const std = @import("std");
const Error = @import("../error.zig").Error;

pub const Tag = enum(u32) {
    unsupported,
    IHDR,
    sRGB,
    gAMA,
    pHYs,
    PLTE,
    tRNS,
    IDAT,
    IEND,
};

len: u32, // 4
tag: Tag, // 8
data: []const u8, // 16 - fat ptr - can convert to ptr but it doesnt save memory
crc: u32 = undefined, // 32

pub fn decode(data: []const u8) !@This() {
    const chunk_size = //
        @sizeOf(@FieldType(@This(), "len")) + //
        @sizeOf(@FieldType(@This(), "tag")) + //
        @sizeOf(@FieldType(@This(), "crc"));
    if (data.len < chunk_size) return Error.OutOfBounds;
    const len: u32 = std.mem.readInt(u32, data[0..][0..4], .big);
    if (data[chunk_size..].len < len) return Error.InvalidChunkLen;
    const tag = std.meta.stringToEnum(Tag, data[4..][0..4]) orelse //
        .unsupported;
    const data1 = switch (tag) {
        .unsupported => data[4..][0 .. 4 + len],
        else => data[8..][0..len],
    };
    const crc = std.mem.readInt(u32, data[8 + len ..][0..4], .big);
    return .{
        .len = len,
        .tag = tag,
        .data = data1,
        .crc = crc,
    };
}

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    switch (self.tag) {
        .unsupported => try w.print("{s}?: {}\n", .{ self.data[0..4], self.len }),
        else => try w.print("{t}: {}\n", .{ self.tag, self.len }),
    }
}

pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
    switch (self.tag) {
        .unsupported => return Error.UnsupportedHeader,
        else => {
            try w.writeInt(u32, self.len, .big);
            try w.writeAll(@tagName(self.tag));
            try w.writeAll(self.data);
            try w.writeInt(u32, self.updateCrc(), .big);
        },
    }
}

pub fn updateCrc(self: *const @This()) u32 {
    var h = std.hash.Crc32.init();
    switch (self.tag) {
        .unsupported => {
            h.update(self.data[0..4]);
            h.update(self.data[4..]);
        },
        else => {
            h.update(@tagName(self.tag));
            h.update(self.data);
        },
    }
    return h.final();
}

pub fn validateCrc(self: *const @This()) !void {
    const computed_crc = self.updateCrc();
    if (computed_crc != self.crc) return Error.InvalidCrc;
}

pub fn sizeOf(self: *const @This()) usize {
    var n_data: usize = 0;
    n_data += @sizeOf(@FieldType(@This(), "len"));
    n_data += @sizeOf(@FieldType(@This(), "tag"));
    n_data += switch (self.tag) {
        .unsupported => self.data.len - 4,
        else => self.data.len,
    };
    n_data += @sizeOf(@FieldType(@This(), "crc"));
    return n_data;
}
