//! Row helpers (mostly vector code) shared by the pixel conversions and the raster decoders.
const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

/// Swaps the bytes of every 16-bit sample (`src.len` even, == `dst.len`; `dst` may be
/// `src` itself): big <-> little endian.
pub fn swapBytes16(src: []const u8, dst: []u8) void {
    std.debug.assert(src.len == dst.len and src.len % 2 == 0);
    const L = @import("misc.zig").N / 2;
    var i: usize = 0;
    while (i + 2 * L <= src.len) : (i += 2 * L) {
        const v: @Vector(2 * L, u8) = @bitCast(@byteSwap(load(L, u16, src[i..])));
        dst[i..][0 .. 2 * L].* = v;
    }
    while (i < src.len) : (i += 2) {
        const hi = src[i];
        dst[i] = src[i + 1];
        dst[i + 1] = hi;
    }
}

/// Big-endian 16-bit samples -> native endian (or back: the same operation).
pub fn nativeFromBig16(src: []const u8, dst: []u8) void {
    if (native_endian == .little) return swapBytes16(src, dst);
    if (src.ptr != dst.ptr) @memcpy(dst, src);
}

test swapBytes16 {
    const L = @import("misc.zig").N / 2;
    var buf: [2 * (2 * L + 3)]u8 = undefined;
    for (&buf, 0..) |*b, k| b.* = @intCast(k);
    for ([_]usize{ 0, 1, L - 1, L, L + 1, 2 * L + 3 }) |n| {
        var out: [buf.len]u8 = undefined;
        swapBytes16(buf[0 .. 2 * n], out[0 .. 2 * n]);
        for (0..n) |k| try std.testing.expectEqual(std.mem.readInt(u16, buf[2 * k ..][0..2], .big), std.mem.readInt(u16, out[2 * k ..][0..2], .little));
    }
}

/// `L` native-endian `T`s from the start of `bytes`. A pointer cast compiles to one
/// unaligned load, where `@bitCast` of a byte array becomes a byte-by-byte loop.
pub inline fn load(comptime L: usize, comptime T: type, bytes: []const u8) @Vector(L, T) {
    return @as(*align(1) const [L]T, @ptrCast(bytes[0 .. L * @sizeOf(T)])).*;
}

/// Like `load`, for little-endian file data.
pub inline fn loadLittle(comptime L: usize, comptime T: type, bytes: []const u8) @Vector(L, T) {
    const v = load(L, T, bytes);
    return if (native_endian == .big) @byteSwap(v) else v;
}

/// The memory bytes of `L` pixels packed as `c0 | c1 << 8 | c2 << 16 | c3 << 24`, keeping
/// the first `bpp` (3 or 4) channels. Building pixels as words with shifts and ors, then
/// dropping the 4th byte with a single shuffle, beats interlacing channel vectors.
pub inline fn pixelBytes(comptime bpp: usize, comptime L: usize, words: @Vector(L, u32)) @Vector(L * bpp, u8) {
    const le = if (native_endian == .big) @byteSwap(words) else words;
    const bytes: @Vector(L * 4, u8) = @bitCast(le);
    if (bpp == 4) return bytes;
    comptime std.debug.assert(bpp == 3);
    const mask = comptime blk: {
        var m: [L * 3]i32 = undefined;
        for (0..L) |p| for (0..3) |c| {
            m[p * 3 + c] = p * 4 + c;
        };
        break :blk m;
    };
    return @shuffle(u8, bytes, undefined, mask);
}

/// Rearranges bytes within each of `n` pixels: output byte `c` of a pixel is its input
/// byte `map[c]`, or `fill[c]` where `map[c]` is null (e.g. RGB -> RGBA is
/// .{ 0, 1, 2, null } with alpha 255). Each 16-byte piece of output is one byte shuffle
/// (pshufb / tbl) of a 16-byte load, which beats splitting pixels into channel vectors
/// and interlacing them again when pixels grow; for pixels that shrink, the partial
/// stores make it slower than `std.simd` interlacing.
pub inline fn permute(
    comptime n: usize,
    comptime in_bpp: usize,
    comptime out_bpp: usize,
    comptime map: [out_bpp]?u8,
    comptime fill: [out_bpp]u8,
    src: *const [n * in_bpp]u8,
) [n * out_bpp]u8 {
    // pixels per load: as many whole ones as 16 bytes hold, dividing `n`
    const P = switch (in_bpp) {
        1 => 16,
        2 => 8,
        3, 4 => 4,
        else => @compileError("pixels are 1 to 4 bytes"),
    };
    comptime std.debug.assert(n % P == 0 and n * in_bpp >= 16);
    const zero: @Vector(1, u8) = @splat(0);
    var out: [n * out_bpp]u8 = undefined;
    inline for (0..n / P) |g| {
        const first = g * P * in_bpp;
        // the last 3-byte group would read past the end: load it 4 bytes earlier
        const at = @min(first, n * in_bpp - 16);
        const v: @Vector(16, u8) = src[at..][0..16].*; // fixed: pshufb / tbl shuffle within 16 bytes
        const group_bytes = P * out_bpp;
        inline for (0..(group_bytes + 15) / 16) |piece| {
            const len = @min(16, group_bytes - piece * 16);
            const mask, const constants = comptime blk: {
                var m: [len]i32 = undefined;
                var k: [len]u8 = @splat(0);
                for (&m, &k, piece * 16..) |*e, *f, j| {
                    const c = j % out_bpp;
                    if (map[c]) |byte| {
                        e.* = first - at + j / out_bpp * in_bpp + byte;
                    } else {
                        // a constant lane in the shuffle itself makes LLVM store bytes
                        // one at a time, so take a zero and or the fill in afterwards
                        e.* = -1;
                        f.* = fill[c];
                    }
                }
                break :blk .{ m, k };
            };
            out[g * group_bytes + piece * 16 ..][0..len].* = @shuffle(u8, v, zero, mask) | @as(@Vector(len, u8), constants);
        }
    }
    return out;
}

test permute {
    var src: [32 * 3]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i);
    const rgba = permute(32, 3, 4, .{ 2, 1, 0, null }, .{ 0, 0, 0, 255 }, &src);
    for (0..32) |p| {
        const want = [4]u8{ src[p * 3 + 2], src[p * 3 + 1], src[p * 3], 255 };
        try std.testing.expectEqualSlices(u8, &want, rgba[p * 4 ..][0..4]);
    }
    const ga = permute(32, 3, 2, .{ 1, null }, .{ 0, 9 }, &src);
    for (0..32) |p| try std.testing.expectEqualSlices(u8, &.{ src[p * 3 + 1], 9 }, ga[p * 2 ..][0..2]);
}

/// `std.simd.interlace` (element i of every vector, then element i + 1, ...). std
/// builds its masks at comptime under the default branch quota, which 64-byte vectors
/// (AVX-512) of 3 or 4 channels exceed; those take one big shuffle instead. Smaller
/// ones keep std's, which LLVM lowers better (rgba -> rgb ~25% faster with AVX2).
pub inline fn interlace(vecs: anytype) @Vector(vecs.len * vecLen(@TypeOf(vecs[0])), vecChild(@TypeOf(vecs[0]))) {
    const V = @TypeOf(vecs[0]);
    const K = vecs.len;
    const L = comptime vecLen(V);
    if (K * L <= max_std_lanes) return std.simd.interlace(vecs);
    const arr: [K]V = vecs;
    const joined: @Vector(K * L, vecChild(V)) = @bitCast(arr);
    const mask = comptime blk: {
        @setEvalBranchQuota(10 * K * L + 1000);
        var m: [K * L]i32 = undefined;
        for (0..L) |p| for (0..K) |c| {
            m[p * K + c] = c * L + p;
        };
        break :blk m;
    };
    return @shuffle(vecChild(V), joined, undefined, mask);
}

/// `std.simd.deinterlace`: the inverse of `interlace`, without its branch-quota limit.
pub inline fn deinterlace(comptime K: usize, interlaced: anytype) [K]@Vector(vecLen(@TypeOf(interlaced)) / K, vecChild(@TypeOf(interlaced))) {
    if (comptime vecLen(@TypeOf(interlaced)) <= max_std_lanes) return std.simd.deinterlace(K, interlaced);
    const T = vecChild(@TypeOf(interlaced));
    const L = comptime vecLen(@TypeOf(interlaced)) / K;
    var out: [K]@Vector(L, T) = undefined;
    inline for (&out, 0..) |*o, c| {
        const mask = comptime blk: {
            @setEvalBranchQuota(10 * L + 1000);
            var m: [L]i32 = undefined;
            for (&m, 0..) |*e, p| e.* = p * K + c;
            break :blk m;
        };
        o.* = @shuffle(T, interlaced, undefined, mask);
    }
    return out;
}

/// The widest interlace std's masks stay within the default branch quota for.
const max_std_lanes = 128;

fn vecLen(comptime V: type) usize {
    return @typeInfo(V).vector.len;
}

fn vecChild(comptime V: type) type {
    return @typeInfo(V).vector.child;
}

test "interlace and deinterlace match std.simd" {
    inline for (.{ 2, 3, 4 }) |K| inline for (.{ 4, 16, 32, 64 }) |L| {
        var vecs: [K]@Vector(L, u8) = undefined;
        for (&vecs, 0..) |*v, c| {
            var a: [L]u8 = undefined;
            for (&a, 0..) |*e, p| e.* = @intCast((c * 97 + p * 7) % 256);
            v.* = a;
        }
        const ours = interlace(vecs);
        // the reference, element by element (std's own can't build 64 x 3 or 4 masks)
        const flat: [K * L]u8 = ours;
        for (0..L) |p| for (0..K) |c| try std.testing.expectEqual(@as([L]u8, vecs[c])[p], flat[p * K + c]);
        try std.testing.expectEqual(vecs, deinterlace(K, ours));
    };
}

pub const MinMax = struct { min: u8, max: u8 };

/// Smallest and largest byte of a non-empty slice.
pub fn minMax(bytes: []const u8) MinMax {
    const L = @import("misc.zig").N;
    var lo: @Vector(L, u8) = @splat(255);
    var hi: @Vector(L, u8) = @splat(0);
    var i: usize = 0;
    while (i + L <= bytes.len) : (i += L) {
        const v: @Vector(L, u8) = bytes[i..][0..L].*;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    var r: MinMax = .{ .min = @reduce(.Min, lo), .max = @reduce(.Max, hi) };
    for (bytes[i..]) |b| {
        r.min = @min(r.min, b);
        r.max = @max(r.max, b);
    }
    return r;
}

/// Palette lookup of 8-bit `indices` into 3 or 4-byte pixels. The caller checks the
/// indices; entries are 4 bytes so each lookup is one load and, for 3-byte pixels, one
/// 4-byte store whose extra byte the next pixel overwrites (the last pixel is stored
/// exactly, so nothing past `dst` is touched).
pub fn lookup(comptime bpp: usize, table: *const [256][4]u8, indices: []const u8, dst: []u8) void {
    if (indices.len == 0) return;
    const last = indices.len - 1;
    if (bpp == 4) {
        for (indices, 0..) |idx, x| dst[x * 4 ..][0..4].* = table[idx];
        return;
    }
    for (indices[0..last], 0..) |idx, x| dst[x * 3 ..][0..4].* = table[idx];
    dst[last * 3 ..][0..3].* = table[indices[last]][0..3].*;
}

test minMax {
    var bytes: [100]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(50 + i % 40);
    // extremes in the vector part and in the tail
    bytes[3] = 7;
    try std.testing.expectEqual(@as(u8, 7), minMax(&bytes).min);
    try std.testing.expectEqual(@as(u8, 89), minMax(&bytes).max);
    bytes[99] = 200;
    bytes[98] = 1;
    try std.testing.expectEqual(@as(u8, 200), minMax(&bytes).max);
    try std.testing.expectEqual(@as(u8, 1), minMax(&bytes).min);
    try std.testing.expectEqual(@as(u8, 9), minMax(&.{9}).max);
}

test "minMax at vector-edge lengths vs scalar" {
    const N = @import("misc.zig").N;
    var prng: std.Random.DefaultPrng = .init(3);
    const rand = prng.random();
    var buf: [4 * N + 8]u8 = undefined;
    for ([_]usize{ 1, 2, 7, 15, 17, 33, 65, N - 1, N, N + 1, 2 * N - 1, 2 * N, 2 * N + 3, 4 * N + 7 }) |len| {
        // the extremes at every position: vector body, last lane, tail
        for (0..len) |at| {
            const bytes = buf[0..len];
            for (bytes) |*b| b.* = rand.intRangeAtMost(u8, 40, 200);
            bytes[at] = rand.uintAtMost(u8, 39);
            bytes[len - 1 - at] = rand.intRangeAtMost(u8, 201, 255);
            var want: MinMax = .{ .min = 255, .max = 0 };
            for (bytes) |b| want = .{ .min = @min(want.min, b), .max = @max(want.max, b) };
            try std.testing.expectEqual(want, minMax(bytes));
        }
    }
}

test lookup {
    var table: [256][4]u8 = undefined;
    for (&table, 0..) |*e, i| e.* = .{ @intCast(i), 100, 200, 250 };
    var dst: [3 * 3 + 1]u8 = @splat(0xAA);
    lookup(3, &table, &.{ 5, 6, 7 }, dst[0..9]);
    try std.testing.expectEqualSlices(u8, &.{ 5, 100, 200, 6, 100, 200, 7, 100, 200, 0xAA }, &dst);
    var dst4: [8]u8 = undefined;
    lookup(4, &table, &.{ 1, 2 }, &dst4);
    try std.testing.expectEqualSlices(u8, &.{ 1, 100, 200, 250, 2, 100, 200, 250 }, &dst4);
}

test pixelBytes {
    const words: @Vector(4, u32) = .{ 0x04030201, 0x08070605, 0x0C0B0A09, 0x100F0E0D };
    const four: [16]u8 = pixelBytes(4, 4, words);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, &four);
    const three: [12]u8 = pixelBytes(3, 4, words);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 5, 6, 7, 9, 10, 11, 13, 14, 15 }, &three);
    const halves: [4]u16 = loadLittle(4, u16, &.{ 1, 0, 2, 0, 0, 1, 0xFF, 0xFF });
    try std.testing.expectEqual([4]u16{ 1, 2, 256, 0xFFFF }, halves);
}
