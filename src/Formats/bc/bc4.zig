//! BC4: 8 bytes per 4x4 block of ONE channel. Two u8 endpoints + 3-bit indices.
//! Also the alpha half of BC3 and both halves of BC5.
const std = @import("std");

pub const BLOCK_BYTES = 8;

pub fn palette(e0: u8, e1: u8) [8]u8 {
    var p: [8]u8 = undefined;
    p[0] = e0;
    p[1] = e1;
    const a: u32 = e0;
    const b: u32 = e1;
    if (e0 > e1) {
        for (1..7) |i| p[i + 1] = @intCast(((7 - i) * a + i * b + 3) / 7);
    } else {
        for (1..5) |i| p[i + 1] = @intCast(((5 - i) * a + i * b + 2) / 5);
        p[6] = 0;
        p[7] = 255;
    }
    return p;
}

pub fn decodeBlock(src: *const [8]u8, out: *[16]u8) void {
    const p = palette(src[0], src[1]);
    var bits: u64 = 0;
    for (src[2..8], 0..) |b, i| bits |= @as(u64, b) << @intCast(i * 8);
    for (out, 0..) |*v, i| v.* = p[@intCast((bits >> @intCast(i * 3)) & 7)];
}

pub fn encodeBlock(values: *const [16]u8, out: *[8]u8) void {
    var lo: u8 = 255;
    var hi: u8 = 0;
    for (values) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    out[0] = hi;
    out[1] = lo;
    var bits: u64 = 0;
    if (hi != lo) {
        // 8-value mode (e0 > e1)
        const p = palette(hi, lo);
        for (values, 0..) |v, i| {
            var best: u64 = 0;
            var best_d: u32 = std.math.maxInt(u32);
            for (p, 0..) |c, j| {
                const d: u32 = @abs(@as(i32, v) - c);
                if (d < best_d) {
                    best_d = d;
                    best = j;
                }
            }
            bits |= best << @intCast(i * 3);
        }
    }
    for (out[2..8], 0..) |*b, i| b.* = @truncate(bits >> @intCast(i * 8));
}

test "bc4 round trip" {
    var v: [16]u8 = undefined;
    for (&v, 0..) |*x, i| x.* = @intCast(i * 17);
    var blk: [8]u8 = undefined;
    encodeBlock(&v, &blk);
    var out: [16]u8 = undefined;
    decodeBlock(&blk, &out);
    for (v, out) |a, b| try std.testing.expect(@abs(@as(i32, a) - b) <= 19);
    @memset(&v, 77);
    encodeBlock(&v, &blk);
    decodeBlock(&blk, &out);
    for (out) |b| try std.testing.expectEqual(@as(u8, 77), b);
}
