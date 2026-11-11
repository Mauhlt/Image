//! MSB-first bit writer for entropy-coded JPEG data (inserts 0x00 after every 0xFF).
const std = @import("std");

w: *std.Io.Writer,
acc: u32 = 0,
count: u5 = 0, // pending bits in `acc` (< 8 between calls)

pub fn putBits(self: *@This(), value: u32, len: u5) !void {
    if (len == 0) return;
    var acc: u64 = (@as(u64, self.acc) << len) | (value & ((@as(u32, 1) << len) - 1));
    var count: u7 = @as(u7, self.count) + len;
    while (count >= 8) {
        count -= 8;
        const byte: u8 = @truncate(acc >> @intCast(count));
        try self.w.writeByte(byte);
        if (byte == 0xFF) try self.w.writeByte(0x00);
    }
    acc &= (@as(u64, 1) << @intCast(count)) - 1;
    self.acc = @intCast(acc);
    self.count = @intCast(count);
}

/// Pads the final byte with 1-bits.
pub fn flush(self: *@This()) !void {
    if (self.count == 0) return;
    const pad: u5 = 8 - self.count;
    try self.putBits((@as(u32, 1) << pad) - 1, pad);
}

test "bitwriter stuffs 0xFF" {
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var bw: @This() = .{ .w = &w };
    try bw.putBits(0xF, 4);
    try bw.putBits(0xF, 4);
    try bw.putBits(0x1, 1);
    try bw.flush();
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0x00, 0xFF, 0x00 }, w.buffered());
}
