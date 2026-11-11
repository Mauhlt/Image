//! LSB-first bit reader (VP8L).
//! Reading past the end yields zero bits; `check()` reports whether that happened.
const std = @import("std");
const Error = @import("../error.zig").Error;

data: []const u8,
pos: usize = 0, // bytes fed into `acc`, may exceed data.len (zero padding)
acc: u64 = 0,
count: u7 = 0,

fn fill(self: *@This()) void {
    if (self.pos + 8 <= self.data.len) {
        // as many whole bytes as fit, in one load. The bits of the partial
        // byte above them are that byte's real bits, so the next fill can OR
        // it in again unchanged.
        self.acc |= std.mem.readInt(u64, self.data[self.pos..][0..8], .little) << @intCast(self.count);
        const n = (63 - self.count) >> 3;
        self.pos += n;
        self.count += n * 8;
        return;
    }
    while (self.count <= 56) {
        const byte: u64 = if (self.pos < self.data.len) self.data[self.pos] else 0;
        self.pos += 1;
        self.acc |= byte << @intCast(self.count);
        self.count += 8;
    }
}

pub inline fn peek(self: *@This(), n: u6) u32 {
    if (self.count < n) self.fill();
    return @truncate(self.acc & ((@as(u64, 1) << n) - 1));
}

pub inline fn consume(self: *@This(), n: u6) void {
    self.acc >>= n;
    self.count -= n;
}

pub fn readBits(self: *@This(), n: u6) u32 {
    if (n == 0) return 0;
    const v = self.peek(n);
    self.consume(n);
    return v;
}

pub fn readBit(self: *@This()) bool {
    return self.readBits(1) == 1;
}

/// Errors if any consumed bit came from past the end of `data`.
pub fn check(self: *const @This()) Error!void {
    if (self.pos <= self.data.len) return;
    const padding_bits = (self.pos - self.data.len) * 8;
    if (self.count < padding_bits) return Error.UnexpectedEndOfData;
}

test "lsb first" {
    var br: @This() = .{ .data = &.{ 0b1010_0110, 0xFF } };
    try std.testing.expectEqual(@as(u32, 0b10), br.readBits(2));
    try std.testing.expectEqual(@as(u32, 0b01), br.readBits(2));
    try std.testing.expectEqual(@as(u32, 0b1010), br.readBits(4));
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    try br.check();
    _ = br.readBits(1);
    try std.testing.expectError(Error.UnexpectedEndOfData, br.check());
}
