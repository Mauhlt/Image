//! Row helpers (mostly vector code) shared by the pixel conversions and the raster decoders.
const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();

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
        const v: @Vector(16, u8) = src[at..][0..16].*;
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

pub const MinMax = struct { min: u8, max: u8 };

/// Smallest and largest byte of a non-empty slice.
pub fn minMax(bytes: []const u8) MinMax {
    const L = 32;
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
