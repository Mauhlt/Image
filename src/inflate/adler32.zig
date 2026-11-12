//! Adler-32 (RFC 1950), vectorised. `update(adler, bytes)` chains like zlib's
//! `adler32()`; a fresh checksum starts from 1.
//!
//! Per block of k chunks of W bytes (W = the SIMD tuning width), with b[c][j] the
//! byte at offset c*W + j:
//!   s1 += sum(b)
//!   s2 += k*W*s1 + sum_{c,j} (k*W - c*W - j) * b[c][j]
//!       = k*W*s1 + W * sum_j acc[j] - sum_j j * run[j]
//! where, per lane j, run[j] = sum_c b[c][j] and acc[j] = sum_c (k - c) * b[c][j]
//! (accumulated as "run += b; acc += run"). The inner loop keeps u16 lanes -- half
//! the widening and adding of u32 lanes -- over at most 22 chunks (acc[j] <=
//! 255 * 22 * 23 / 2 < 2^16); up to 64 such sub-blocks are folded into u32 lane
//! totals (acc += sub_acc + sub_k * run; run += sub_run: acc[j] <= 255 * K(K+1)/2
//! < 2^32 for K = 64 * 22 chunks), and only those are reduced to scalars (u64).
const std = @import("std");
const W = @import("../Colors/misc.zig").N;

const base = 65521;
const sub_chunks = 22;
const max_subs = 64;

pub fn update(adler: u32, bytes: []const u8) u32 {
    var s1: u64 = adler & 0xffff;
    var s2: u64 = adler >> 16;
    var p = bytes;
    const U16 = @Vector(W, u16);
    const U32 = @Vector(W, u32);
    const iota: U32 = std.simd.iota(u32, W);
    while (p.len >= W) {
        var run: U32 = @splat(0);
        var acc: U32 = @splat(0);
        var chunks: usize = 0;
        var subs: usize = 0;
        while (subs < max_subs and p.len >= W) : (subs += 1) {
            const k = @min(p.len / W, sub_chunks);
            var r16: U16 = @splat(0);
            var a16: U16 = @splat(0);
            for (0..k) |c| {
                const v: @Vector(W, u8) = p[c * W ..][0..W].*;
                r16 += @as(U16, v);
                a16 += r16;
            }
            acc += @as(U32, a16) + @as(U32, @splat(@intCast(k))) * run;
            run += @as(U32, r16);
            chunks += k;
            p = p[k * W ..];
        }
        const n: u64 = chunks * W;
        const sum_run: u64 = @reduce(.Add, @as(@Vector(W, u64), run));
        const sum_acc: u64 = @reduce(.Add, @as(@Vector(W, u64), acc));
        const sum_jrun: u64 = @reduce(.Add, @as(@Vector(W, u64), run) * @as(@Vector(W, u64), iota));
        s2 = (s2 + n * s1 + W * sum_acc - sum_jrun) % base;
        s1 = (s1 + sum_run) % base;
    }
    for (p) |b| {
        s1 += b;
        s2 += s1;
    }
    return @intCast((s2 % base) << 16 | (s1 % base));
}

pub fn hash(bytes: []const u8) u32 {
    return update(1, bytes);
}

/// Bytewise reference.
fn slow(adler: u32, bytes: []const u8) u32 {
    var s1: u32 = adler & 0xffff;
    var s2: u32 = adler >> 16;
    for (bytes) |b| {
        s1 = (s1 + b) % base;
        s2 = (s2 + s1) % base;
    }
    return s2 << 16 | s1;
}

test "adler32 matches reference for every length, all-0xff worst case, chaining" {
    try std.testing.expectEqual(@as(u32, 0x11E60398), hash("Wikipedia"));
    var buf: [3000]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(7);
    rng.random().bytes(&buf);
    for (0..buf.len + 1) |n| try std.testing.expectEqual(slow(1, buf[0..n]), hash(buf[0..n]));
    try std.testing.expectEqual(slow(0xfff0fff0, buf[0..1234]), update(0xfff0fff0, buf[0..1234]));
    // large all-0xff input exercises the lane overflow bound across several blocks
    const big = try std.testing.allocator.alloc(u8, W * sub_chunks * max_subs * 3 + 1234);
    defer std.testing.allocator.free(big);
    @memset(big, 0xff);
    try std.testing.expectEqual(slow(1, big), hash(big));
    try std.testing.expectEqual(std.hash.Adler32.hash(big), hash(big));
}
