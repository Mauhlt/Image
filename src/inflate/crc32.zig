//! CRC-32 (IEEE 802.3; reflected polynomial 0xEDB88320) -- the checksum of gzip, PNG
//! and zlib's `crc32()`. `update(crc, bytes)` chains like zlib: `update(0, "")` is 0
//! and `update(update(0, a), b) == update(0, a ++ b)`.
//!
//! Two kernels, picked at comptime from `builtin.cpu.features`:
//!   * carry-less multiply folding (x86_64 PCLMULQDQ, aarch64 PMULL): 8 x 128-bit
//!     accumulators, each folded 1024 bits forward per round;
//!   * portable slicing-by-16 tables (16 KiB), for everything else and for the
//!     short head/tail of a buffer.
//! The fold constants are computed at comptime from the polynomial (no magic numbers),
//! and the folded remainder is reduced by running its 16 bytes through the table
//! kernel, so there is no Barrett step to get wrong.
const std = @import("std");
const builtin = @import("builtin");

/// Reflected CRC-32 polynomial (bit i = coefficient of x^(31-i)).
const poly_reflected: u32 = 0xEDB88320;
/// Same polynomial, normal form without the x^32 term (bit i = coefficient of x^i).
const poly_normal: u64 = 0x1_04C11DB7;

const Clmul = enum { none, pclmul, pclmul_avx, pmull };

/// Which carry-less multiply the target has (comptime).
pub const clmul: Clmul = switch (builtin.cpu.arch) {
    .x86_64 => if (std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul))
        (if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx)) .pclmul_avx else .pclmul)
    else
        .none,
    // PMULL (64x64 -> 128 polynomial multiply) is part of the AES extension.
    .aarch64 => if (std.Target.aarch64.featureSetHas(builtin.cpu.features, .aes)) .pmull else .none,
    else => .none,
};

/// CRC of `bytes` continuing from `crc` (0 for a fresh checksum).
pub fn update(crc: u32, bytes: []const u8) u32 {
    return ~updateRaw(~crc, bytes);
}

/// CRC of `bytes`.
pub fn hash(bytes: []const u8) u32 {
    return update(0, bytes);
}

/// The portable kernel only (for tests and benchmarks).
pub fn updatePortable(crc: u32, bytes: []const u8) u32 {
    return ~tableUpdate(~crc, bytes);
}

/// Raw LFSR state update (no pre/post inversion).
fn updateRaw(state: u32, bytes: []const u8) u32 {
    if (clmul != .none and bytes.len >= fold_min) return foldUpdate(state, bytes);
    return tableUpdate(state, bytes);
}

// ───────────────────────────── portable: slicing-by-16 ─────────────────────────────

const tables: [16][256]u32 = blk: {
    @setEvalBranchQuota(20000);
    var t: [16][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = i;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ poly_reflected else c >> 1;
        t[0][i] = c;
    }
    for (0..256) |i| {
        for (1..16) |k| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :blk t;
};

fn tableUpdate(state: u32, bytes: []const u8) u32 {
    var c = state;
    var p = bytes;
    while (p.len >= 16) : (p = p[16..]) {
        // 16 bytes per step: the first 4 absorb the state, all 16 are looked up in
        // parallel tables (t[k] = effect of a byte followed by k zero bytes).
        const a = std.mem.readInt(u32, p[0..4], .little) ^ c;
        const b = std.mem.readInt(u32, p[4..8], .little);
        const d = std.mem.readInt(u32, p[8..12], .little);
        const e = std.mem.readInt(u32, p[12..16], .little);
        c = tables[15][a & 0xff] ^ tables[14][(a >> 8) & 0xff] ^ tables[13][(a >> 16) & 0xff] ^ tables[12][a >> 24] ^
            tables[11][b & 0xff] ^ tables[10][(b >> 8) & 0xff] ^ tables[9][(b >> 16) & 0xff] ^ tables[8][b >> 24] ^
            tables[7][d & 0xff] ^ tables[6][(d >> 8) & 0xff] ^ tables[5][(d >> 16) & 0xff] ^ tables[4][d >> 24] ^
            tables[3][e & 0xff] ^ tables[2][(e >> 8) & 0xff] ^ tables[1][(e >> 16) & 0xff] ^ tables[0][e >> 24];
    }
    for (p) |byte| c = (c >> 8) ^ tables[0][(c ^ byte) & 0xff];
    return c;
}

// ───────────────────────────── carry-less multiply folding ─────────────────────────────
//
// Representation: 16 message bytes loaded little-endian into a u128 are a polynomial
// X of degree < 128 whose bit i is the coefficient of x^(127-i) (bit-reflected, as the
// CRC consumes the stream LSB first). Split X = Xh*x^64 + Xl, where Xh is the low
// qword and Xl the high qword, each a reflected 64-bit polynomial. Moving X forward by
// D bits needs X*x^D = Xh*x^(D+64) + Xl*x^D (mod P). A reflected clmul of two 64-bit
// values yields their product times x, so the constants are x^(D+63) mod P (for Xh,
// low qword) and x^(D-1) mod P (for Xl, high qword); both products stay below 2^128.
// The 128-bit lanes are what PCLMULQDQ/PMULL operate on (not a tuning width).

const Q = @Vector(2, u64);

/// x^n mod P, as a reflected 64-bit value (coefficient of x^j at bit 63-j).
fn xPowModP(n: usize) u64 {
    var r: u64 = 1;
    for (0..n) |_| {
        r <<= 1;
        if (r & (1 << 32) != 0) r ^= poly_normal;
    }
    var out: u64 = 0;
    for (0..32) |j| {
        if (r >> @intCast(j) & 1 != 0) out |= @as(u64, 1) << @intCast(63 - j);
    }
    return out;
}

fn foldConsts(comptime d: usize) Q {
    @setEvalBranchQuota(200000);
    return comptime .{ xPowModP(d + 63), xPowModP(d - 1) };
}

/// Parallel accumulators: enough independent fold chains to cover the clmul latency.
const lanes = 8;
const k_lanes = foldConsts(128 * lanes);
const k_one = foldConsts(128);
const fold_min = 16 * lanes * 2;

inline fn clmulLo(a: Q, b: Q) Q {
    return clmulImm(a, b, 0x00);
}
inline fn clmulHi(a: Q, b: Q) Q {
    return clmulImm(a, b, 0x11);
}

inline fn clmulImm(a: Q, b: Q, comptime imm: u8) Q {
    switch (clmul) {
        .pclmul_avx => return asm (std.fmt.comptimePrint("vpclmulqdq ${d}, %[b], %[a], %[out]", .{imm})
            : [out] "=x" (-> Q),
            : [a] "x" (a),
              [b] "x" (b),
        ),
        .pclmul => return asm (std.fmt.comptimePrint("pclmulqdq ${d}, %[b], %[out]", .{imm})
            : [out] "=x" (-> Q),
            : [a] "0" (a),
              [b] "x" (b),
        ),
        .pmull => return if (imm == 0x00) asm ("pmull %[out].1q, %[a].1d, %[b].1d"
            : [out] "=w" (-> Q),
            : [a] "w" (a),
              [b] "w" (b),
        ) else asm ("pmull2 %[out].1q, %[a].2d, %[b].2d"
            : [out] "=w" (-> Q),
            : [a] "w" (a),
              [b] "w" (b),
        ),
        .none => unreachable,
    }
}

inline fn fold(x: Q, k: Q) Q {
    return clmulLo(x, k) ^ clmulHi(x, k);
}

inline fn load(p: *const [16]u8) Q {
    return .{ std.mem.readInt(u64, p[0..8], .little), std.mem.readInt(u64, p[8..16], .little) };
}

fn foldUpdate(state: u32, bytes: []const u8) u32 {
    const blk = 16 * lanes;
    var x: [lanes]Q = undefined;
    inline for (0..lanes) |i| x[i] = load(bytes[16 * i ..][0..16]);
    x[0][0] ^= state; // the running state joins the first 32 message bits
    var p: usize = blk;
    while (bytes.len - p >= blk) : (p += blk) {
        inline for (0..lanes) |i| x[i] = fold(x[i], k_lanes) ^ load(bytes[p + 16 * i ..][0..16]);
    }
    var y = x[0];
    inline for (1..lanes) |i| y = fold(y, k_one) ^ x[i];
    while (bytes.len - p >= 16) : (p += 16) y = fold(y, k_one) ^ load(bytes[p..][0..16]);
    // remainder polynomial y (128 bits, nothing after it): CRC state = y*x^32 mod P,
    // which is the table kernel run from state 0 over y's bytes.
    var yb: [16]u8 = undefined;
    std.mem.writeInt(u64, yb[0..8], y[0], .little);
    std.mem.writeInt(u64, yb[8..16], y[1], .little);
    return tableUpdate(tableUpdate(0, &yb), bytes[p..]);
}

// ───────────────────────────── tests ─────────────────────────────

fn bitwise(crc: u32, bytes: []const u8) u32 {
    var c = ~crc;
    for (bytes) |b| {
        c ^= b;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ poly_reflected else c >> 1;
    }
    return ~c;
}

test "crc32 known values" {
    try std.testing.expectEqual(@as(u32, 0), hash(""));
    try std.testing.expectEqual(@as(u32, 0xCBF43926), hash("123456789"));
    try std.testing.expectEqual(@as(u32, 0x414FA339), hash("The quick brown fox jumps over the lazy dog"));
}

test "crc32 kernels agree for every length and alignment" {
    var buf: [4096 + 64]u8 = undefined;
    var rng: std.Random.DefaultPrng = .init(0x5eed);
    rng.random().bytes(&buf);
    var len: usize = 0;
    while (len <= 4096) : (len += if (len < 600) 1 else 97) {
        for ([_]usize{ 0, 1, 7, 13 }) |off| {
            const s = buf[off..][0..len];
            const want = std.hash.Crc32.hash(s);
            try std.testing.expectEqual(want, hash(s));
            try std.testing.expectEqual(want, updatePortable(0, s));
            // chaining across an arbitrary split
            const cut = len / 3;
            try std.testing.expectEqual(want, update(update(0, s[0..cut]), s[cut..]));
        }
    }
    try std.testing.expectEqual(bitwise(0x12345678, buf[0..1000]), update(0x12345678, buf[0..1000]));
}
