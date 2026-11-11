//! JFIF YCbCr -> interleaved RGB, `V` (upsample.V) pixels per step. Gives exactly the results of
//! the 16.16 fixed-point formulas in Colors/misc.zig (red/green/blue).
const std = @import("std");
const V = @import("upsample.zig").V;

const I32x = @Vector(V, i32);
const U8x = @Vector(V, u8);
const I16x = @Vector(V, i16);

/// `y`, `cb` and `cr` must be readable up to a whole vector past `dst.len / 3`.
pub fn toRgbRow(y: []const u8, cb: []const u8, cr: []const u8, dst: []u8) void {
    const n = dst.len / 3;
    var x: usize = 0;
    while (x + V <= n) : (x += V) {
        const rgb = toRgb(y[x..][0..V].*, cb[x..][0..V].*, cr[x..][0..V].*);
        inline for (rgb, 0..) |v, i| dst[3 * x + i * V ..][0..V].* = v;
    }
    if (x < n) {
        var tail: [3 * V]u8 = undefined;
        const rgb = toRgb(y[x..][0..V].*, cb[x..][0..V].*, cr[x..][0..V].*);
        inline for (rgb, 0..) |v, i| tail[i * V ..][0..V].* = v;
        @memcpy(dst[3 * x ..], tail[0 .. 3 * (n - x)]);
    }
}

/// Exact rewrites of the 16.16 formulas that keep red and blue in 16-bit lanes:
///   (k c + 2^15) >> 16 == (((k c) >> 15) + 1) >> 1, and k c >> 15 is a 16-bit
///   high multiply (x86 pmulhw) once k is split so the factors fit i16:
///   red:   91881 c = 65536 c + 26345 c   ->  c + ((mulhi(2c, 26345) + 1) >> 1)
///   blue: 116130 c = 131072 c - 14942 c  -> 2c + ((mulhi(c, -29884) + 1) >> 1)
///   green: -46802 cr = -65536 cr + 18734 cr, halved: -cr + (-11277 cb + 9367 cr + 2^14) >> 15
fn toRgb(y: U8x, cb: U8x, cr: U8x) [3]U8x {
    const one: I16x = @splat(1);
    const yi: I16x = y;
    const cbi = @as(I16x, cb) - @as(I16x, @splat(128));
    const cri = @as(I16x, cr) - @as(I16x, @splat(128));
    const r = yi + cri + ((mulhi(cri + cri, 26345) + one) >> one);
    const b = yi + cbi + cbi + ((mulhi(cbi, -29884) + one) >> one);
    const g_dot = @as(I32x, cbi) * @as(I32x, @splat(-11277)) + @as(I32x, cri) * @as(I32x, @splat(9367));
    const g = yi - cri + @as(I16x, @intCast((g_dot + @as(I32x, @splat(1 << 14))) >> @splat(15)));
    return interleave(clamp(r), clamp(g), clamp(b));
}

/// Signed high half of a 16 x 16-bit product, (a * b) >> 16.
fn mulhi(a: I16x, comptime b: i16) I16x {
    return @intCast((@as(I32x, a) * @as(I32x, @splat(b))) >> @splat(16));
}

fn clamp(v: I16x) U8x {
    return @intCast(@min(@max(v, @as(I16x, @splat(0))), @as(I16x, @splat(255))));
}

/// Interleaves r, g, b into three vectors: r0 g0 b0 r1 g1 b1 ... Each output vector
/// is an OR of one in-register byte shuffle per channel (pshufb on x86), which is far
/// cheaper than a general 48-byte shuffle.
fn interleave(r: U8x, g: U8x, b: U8x) [3]U8x {
    var out: [3]U8x = undefined;
    inline for (&out, 0..) |*o, chunk| o.* = pick(r, chunk, 0) | pick(g, chunk, 1) | pick(b, chunk, 2);
    return out;
}

/// The bytes of channel `ch` that land in output vector `chunk`, zeros elsewhere.
inline fn pick(v: U8x, comptime chunk: usize, comptime ch: usize) U8x {
    const mask = comptime blk: {
        var m: [V]i32 = undefined;
        for (&m, chunk * V..) |*e, pos| e.* = if (pos % 3 == ch) pos / 3 else -1; // -1: zero
        break :blk m;
    };
    return @shuffle(u8, v, @as(U8x, @splat(0)), mask);
}

test "vector conversion matches the scalar formulas for every input" {
    const color = @import("../../Colors/misc.zig");
    var y: [V]u8 = undefined;
    var cb: [V]u8 = undefined;
    var cr: [V]u8 = undefined;
    var rgb: [3 * V]u8 = undefined;
    for (0..256) |yy| for (0..256) |c| {
        // each lane takes a different Cr so all 256^3 combinations are covered
        for (0..V) |i| {
            y[i] = @intCast(yy);
            cb[i] = @intCast(c);
        }
        var base: usize = 0;
        while (base < 256) : (base += V) {
            for (&cr, 0..) |*v, i| v.* = @intCast(base + i);
            toRgbRow(&y, &cb, &cr, &rgb);
            for (0..V) |i| {
                try std.testing.expectEqual(color.red(y[i], cr[i]), rgb[3 * i]);
                try std.testing.expectEqual(color.green(y[i], cb[i], cr[i]), rgb[3 * i + 1]);
                try std.testing.expectEqual(color.blue(y[i], cb[i]), rgb[3 * i + 2]);
            }
        }
    };
}
