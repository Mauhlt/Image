//! MSB-first bit reader over entropy-coded JPEG data.
//! Handles 0xFF00 byte stuffing; when a marker is reached it feeds zeros
//! (the caller decides whether that is a restart marker or the end).
const std = @import("std");
const Error = @import("../error.zig").Error;
const huffman = @import("huffman.zig");

data: []const u8,
pos: usize = 0,
acc: u64 = 0,
count: u7 = 0, // valid bits in `acc` (right aligned)
hit_marker: bool = false,

fn fill(self: *@This()) void {
    while (self.count <= 56) {
        var byte: u8 = 0;
        if (!self.hit_marker and self.pos < self.data.len) {
            byte = self.data[self.pos];
            if (byte == 0xFF) {
                const next: u8 = if (self.pos + 1 < self.data.len) self.data[self.pos + 1] else 0xD9;
                if (next == 0x00) {
                    self.pos += 2;
                } else {
                    self.hit_marker = true; // leave pos on the marker
                    byte = 0;
                }
            } else {
                self.pos += 1;
            }
        }
        self.acc = (self.acc << 8) | byte;
        self.count += 8;
    }
}

pub inline fn peek(self: *@This(), comptime n: u5) u32 {
    if (self.count < n) self.fill();
    return @truncate((self.acc >> @intCast(self.count - n)) & ((@as(u64, 1) << n) - 1));
}

pub inline fn consume(self: *@This(), n: u7) void {
    self.count -= n;
}

pub fn readBits(self: *@This(), n: u5) u32 {
    if (n == 0) return 0;
    if (self.count < n) self.fill();
    self.count -= n;
    return @truncate((self.acc >> @intCast(self.count)) & ((@as(u64, 1) << n) - 1));
}

/// Reads `s` bits and sign-extends them (F.2.2.1 EXTEND).
pub fn receiveExtend(self: *@This(), s: u5) i32 {
    if (s == 0) return 0;
    const v: i32 = @intCast(self.readBits(s));
    return if (v < (@as(i32, 1) << (s - 1))) v - (@as(i32, 1) << s) + 1 else v;
}

pub fn decodeSymbol(self: *@This(), t: *const huffman.DecTable) Error!u8 {
    if (self.count < 16) self.fill();
    const entry = t.lookup[self.peek(huffman.LOOKAHEAD)];
    if (entry >> 8 != 0) {
        self.consume(@intCast(entry >> 8));
        return @truncate(entry);
    }
    inline for (huffman.LOOKAHEAD + 1..17) |len| {
        const code: i32 = @intCast(self.peek(len));
        if (code <= t.maxcode[len]) {
            self.consume(len);
            return t.values[@intCast(code + t.delta[len])];
        }
    }
    return Error.InvalidHuffmanCode;
}

/// Discards buffered bits and skips an RSTn marker at the current position.
pub fn restart(self: *@This()) Error!void {
    self.acc = 0;
    self.count = 0;
    self.hit_marker = false;
    // tolerate fill bytes before the marker
    while (self.pos < self.data.len and self.data[self.pos] == 0xFF and
        self.pos + 1 < self.data.len and self.data[self.pos + 1] == 0xFF) self.pos += 1;
    if (self.pos + 1 >= self.data.len or self.data[self.pos] != 0xFF) return Error.InvalidMarker;
    const m = self.data[self.pos + 1];
    if (m < 0xD0 or m > 0xD7) return Error.InvalidMarker;
    self.pos += 2;
}

test "bitreader unstuffs 0xFF00" {
    var br: @This() = .{ .data = &.{ 0xFF, 0x00, 0xA5, 0xFF, 0xD9 } };
    try std.testing.expectEqual(@as(u32, 0xFF), br.readBits(8));
    try std.testing.expectEqual(@as(u32, 0xA), br.readBits(4));
    try std.testing.expectEqual(@as(u32, 0x5), br.readBits(4));
    try std.testing.expectEqual(@as(u32, 0), br.readBits(8)); // marker -> zeros
    try std.testing.expect(br.hit_marker);
}
