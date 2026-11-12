//! 2..16-bit samples (lossless JPEG, JPEG-LS) -> Image's pixel formats:
//!   - gray with P > 8 keeps 16 bits (`.g16`), scaled to the full range:
//!         v16 = (v * 65535 + maxval / 2) / maxval,   exact (v16 = v) for P = 16
//!   - everything else (gray P <= 8, color) goes to 8 bits:
//!         v8 = (v * 255 + maxval / 2) / maxval,   maxval = 2^P - 1
//! i.e. scaled by the actual precision P and rounded to nearest, so P = 8 is the
//! identity. Samples above maxval (only from corrupt streams) clamp to the top.
const std = @import("std");
const Error = @import("../error.zig").Error;
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;

/// u32 / f32 lanes per vector: one tuning-width vector (`-Dvector-bytes`) of 32-bit lanes.
const L = @import("../../Colors/misc.zig").N / 4;
const U32 = @Vector(L, u32);
const I32 = @Vector(L, i32);
const F32 = @Vector(L, f32);

/// Pixel layout for a component count and precision: 1 -> .g (.g16 above 8 bits),
/// 3 -> .rgb (stored as RGB, no YCbCr transform in lossless JPEG / JPEG-LS);
/// anything else is unsupported.
pub fn tagFor(components: u8, precision: u8) Error!PixelTag {
    return switch (components) {
        1 => if (precision > 8) .g16 else .g,
        3 => .rgb,
        else => Error.UnsupportedFeature,
    };
}

pub fn maxval(precision: u8) u32 {
    return (@as(u32, 1) << @intCast(precision)) - 1;
}

/// Writes `samples` as `tag` pixels (from `tagFor`) into `out`.
pub fn store(samples: []const u16, precision: u8, tag: PixelTag, out: []u8) void {
    if (tag == .g16) return toU16(samples, precision, std.mem.bytesAsSlice(u16, out));
    toU8(samples, precision, out);
}

/// One sample to 16 bits, scalar (f64, see `toU16`).
pub fn sample16(v: u16, precision: u8) u16 {
    const m = maxval(precision);
    const x: f64 = @floatFromInt(@min(@as(u32, v), m) * 65535);
    return @intFromFloat(x / @as(f64, @floatFromInt(m)) + 0.5);
}

/// `out[i] = sample16(samples[i], precision)`; `precision` is 9..16.
/// f64 is exact here: v * 65535 < 2^32 is exact, and a quotient that is not a tie
/// lies >= 1 / (2 * maxval) from k + 0.5, far above the division's rounding error.
pub fn toU16(samples: []const u16, precision: u8, out: []align(1) u16) void {
    std.debug.assert(out.len == samples.len);
    std.debug.assert(precision > 8 and precision <= 16);
    if (precision == 16) return @memcpy(std.mem.sliceAsBytes(out), std.mem.sliceAsBytes(samples));
    const W = L / 2; // f64 lanes
    const F64 = @Vector(W, f64);
    const m = maxval(precision);
    const top: @Vector(W, u32) = @splat(m);
    const div: F64 = @splat(@floatFromInt(m));
    var i: usize = 0;
    while (i + W <= samples.len) : (i += W) {
        const v: @Vector(W, u16) = samples[i..][0..W].*;
        const x: F64 = @floatFromInt(@min(@as(@Vector(W, u32), v), top) * @as(@Vector(W, u32), @splat(65535)));
        out[i..][0..W].* = @as(@Vector(W, u16), @intFromFloat(x / div + @as(F64, @splat(0.5))));
    }
    for (samples[i..], out[i..]) |v, *o| o.* = sample16(v, precision);
}

/// One sample, scalar.
pub fn sample(v: u16, precision: u8) u8 {
    const m = maxval(precision);
    return @intCast(@min((@as(u32, v) * 255 + m / 2) / m, 255));
}

/// `out[i] = sample(samples[i], precision)`; `precision` is 2..16.
pub fn toU8(samples: []const u16, precision: u8, out: []u8) void {
    std.debug.assert(out.len == samples.len);
    std.debug.assert(precision >= 2 and precision <= 16);
    var i: usize = 0;
    if (precision == 8) {
        while (i + L <= samples.len) : (i += L) {
            const v: @Vector(L, u16) = samples[i..][0..L].*;
            const o: @Vector(L, u8) = @intCast(@min(v, @as(@Vector(L, u16), @splat(255))));
            out[i..][0..L].* = o;
        }
    } else {
        // x = v * 255 + maxval / 2 < 2^24 is exact in f32. The quotient from the
        // reciprocal multiply is within 1 of floor(x / maxval); one remainder test
        // each way makes it exact.
        const m = maxval(precision);
        const d: I32 = @splat(@intCast(m));
        const half: U32 = @splat(m / 2);
        const inv: F32 = @splat(1.0 / @as(f32, @floatFromInt(m)));
        while (i + L <= samples.len) : (i += L) {
            const v: @Vector(L, u16) = samples[i..][0..L].*;
            const x: I32 = @intCast(@as(U32, v) * @as(U32, @splat(255)) + half);
            var q: I32 = @intFromFloat(@as(F32, @floatFromInt(x)) * inv);
            const r = x - q * d;
            q -= @intFromBool(r < @as(I32, @splat(0)));
            q += @intFromBool(r >= d);
            // via u32: Debug builds (self-hosted x86 backend) narrow i32 -> u8 vectors with
            // signed saturation, turning 128..255 into 127
            const clamped: U32 = @bitCast(@min(q, @as(I32, @splat(255))));
            const o: @Vector(L, u8) = @intCast(clamped);
            out[i..][0..L].* = o;
        }
    }
    for (samples[i..], out[i..]) |v, *o| o.* = sample(v, precision);
}

// ───────────────────────────── Tests ─────────────────────────────

/// Plain integer reference, independent of `sample`.
fn reference(v: u16, precision: u8) u8 {
    const m: u64 = (@as(u64, 1) << @intCast(precision)) - 1;
    const q = (@as(u64, v) * 255 + m / 2) / m;
    return @intCast(@min(q, 255));
}

test "toU8 matches the integer formula for every value of every precision" {
    const gpa = std.testing.allocator;
    // every u16, so values above maxval (clamped) are covered too; the odd
    // length leaves a scalar tail for any vector width
    const n = 65536 + 3;
    const samples = try gpa.alloc(u16, n);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| s.* = @truncate(i *% 40503);
    const out = try gpa.alloc(u8, n);
    defer gpa.free(out);
    for (2..17) |p| {
        const precision: u8 = @intCast(p);
        toU8(samples, precision, out);
        for (samples, out) |s, o| {
            if (o != reference(s, precision)) {
                std.debug.print("P={} v={} got {} want {}\n", .{ precision, s, o, reference(s, precision) });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "toU8 endpoints and the P = 8 identity" {
    for ([_]u8{ 2, 8, 12, 16 }) |p| {
        var out: [2]u8 = undefined;
        toU8(&.{ 0, @intCast(maxval(p)) }, p, &out);
        try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, &out);
    }
    // 2 bit: 0, 85, 170, 255
    var out2: [4]u8 = undefined;
    toU8(&.{ 0, 1, 2, 3 }, 2, &out2);
    try std.testing.expectEqualSlices(u8, &.{ 0, 85, 170, 255 }, &out2);
    var in8: [300]u16 = undefined;
    var out8: [300]u8 = undefined;
    for (&in8, 0..) |*v, i| v.* = @intCast(i % 256);
    toU8(&in8, 8, &out8);
    for (in8, out8) |v, o| try std.testing.expectEqual(@as(u8, @intCast(v)), o);
}

test "tagFor" {
    try std.testing.expectEqual(PixelTag.g, try tagFor(1, 8));
    try std.testing.expectEqual(PixelTag.g16, try tagFor(1, 9));
    try std.testing.expectEqual(PixelTag.g16, try tagFor(1, 16));
    try std.testing.expectEqual(PixelTag.rgb, try tagFor(3, 8));
    try std.testing.expectEqual(PixelTag.rgb, try tagFor(3, 16));
    try std.testing.expectError(Error.UnsupportedFeature, tagFor(2, 8));
    try std.testing.expectError(Error.UnsupportedFeature, tagFor(4, 12));
}

/// Plain integer reference for `sample16`.
fn reference16(v: u16, precision: u8) u16 {
    const m: u64 = (@as(u64, 1) << @intCast(precision)) - 1;
    return @intCast((@min(@as(u64, v), m) * 65535 + m / 2) / m);
}

test "toU16 matches the integer formula for every value of every precision > 8" {
    const gpa = std.testing.allocator;
    const n = 65536 + 3; // every u16 (above maxval too), and a scalar tail
    const samples = try gpa.alloc(u16, n);
    defer gpa.free(samples);
    for (samples, 0..) |*s, i| s.* = @truncate(i *% 40503);
    const out = try gpa.alloc(u16, n);
    defer gpa.free(out);
    for (9..17) |p| {
        const precision: u8 = @intCast(p);
        toU16(samples, precision, out);
        for (samples, out) |s, o| {
            if (o != reference16(s, precision)) {
                std.debug.print("P={} v={} got {} want {}\n", .{ precision, s, o, reference16(s, precision) });
                return error.TestExpectedEqual;
            }
        }
    }
    // endpoints: 0 -> 0, maxval -> 65535
    for (9..17) |p| {
        var o: [2]u16 = undefined;
        toU16(&.{ 0, @intCast(maxval(@intCast(p))) }, @intCast(p), &o);
        try std.testing.expectEqualSlices(u16, &.{ 0, 65535 }, &o);
    }
}
