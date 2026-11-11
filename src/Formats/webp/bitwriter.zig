//! LSB-first bit writer (VP8L) into a growable buffer.
const std = @import("std");

gpa: std.mem.Allocator,
out: std.ArrayList(u8) = .empty,
acc: u64 = 0,
count: u7 = 0,

pub fn deinit(self: *@This()) void {
    self.out.deinit(self.gpa);
}

pub fn writeBits(self: *@This(), value: u32, n: u6) !void {
    if (n == 0) return;
    std.debug.assert(n <= 32);
    self.acc |= (@as(u64, value) & ((@as(u64, 1) << n) - 1)) << @intCast(self.count);
    self.count += n;
    while (self.count >= 8) {
        try self.out.append(self.gpa, @truncate(self.acc));
        self.acc >>= 8;
        self.count -= 8;
    }
}

/// Huffman codes are defined MSB-first; VP8L streams them LSB-first, so reverse.
pub fn writeCode(self: *@This(), code: u16, len: u4) !void {
    if (len == 0) return;
    const rev = @bitReverse(code) >> @intCast(16 - @as(u5, len));
    try self.writeBits(rev, len);
}

pub fn finish(self: *@This()) ![]const u8 {
    if (self.count > 0) {
        try self.out.append(self.gpa, @truncate(self.acc));
        self.acc = 0;
        self.count = 0;
    }
    return self.out.items;
}
