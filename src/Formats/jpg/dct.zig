//! Separable 8x8 DCT-II / DCT-III using @Vector(8, f32) rows.
//! C[u][x] = c(u)/2 * cos((2x+1)u*pi/16), c(0) = 1/sqrt(2). The basis is orthonormal,
//! so the inverse uses the same matrix transposed.
const std = @import("std");

const V8 = @Vector(8, f32);

/// BASIS[u] = C[u][0..8]  (vector over x)
const BASIS: [8]V8 = blk: {
    @setEvalBranchQuota(10_000);
    var b: [8]V8 = undefined;
    for (0..8) |u| {
        var row: [8]f32 = undefined;
        const cu: f64 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
        for (0..8) |x| {
            const angle = @as(f64, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0;
            row[x] = @floatCast(0.5 * cu * @cos(angle));
        }
        b[u] = row;
    }
    break :blk b;
};

/// BASIS_T[x] = C[0..8][x]  (vector over u)
const BASIS_T: [8]V8 = blk: {
    var b: [8]V8 = undefined;
    for (0..8) |x| {
        var row: [8]f32 = undefined;
        for (0..8) |u| row[u] = BASIS[u][x];
        b[x] = row;
    }
    break :blk b;
};

/// coefficients (natural order) -> samples (row-major)
///
/// After quantization the bottom rows of a block are usually all zero, and a zero
/// row adds exactly zero to every sum, so only rows up to the last nonzero one are
/// transformed. The remaining terms are added in the same order as the full matrix
/// product, which keeps the f32 result bit-identical.
pub fn inverse(coeffs: *const [64]f32) [64]f32 {
    var nonzero: u8 = 0;
    inline for (0..8) |v| {
        const row: V8 = coeffs[v * 8 ..][0..8].*;
        if (@reduce(.Or, row != @as(V8, @splat(0)))) nonzero |= 1 << v;
    }
    const n_rows = 8 - @clz(nonzero);

    // rows: tmp[v] = sum_u F[v][u] * C[u][.]
    var tmp: [8]V8 = undefined;
    for (tmp[0..n_rows], 0..) |*t, v| {
        var acc: V8 = @splat(0);
        inline for (0..8) |u| acc += @as(V8, @splat(coeffs[v * 8 + u])) * BASIS[u];
        t.* = acc;
    }
    // columns: out[y] = sum_v C[v][y] * tmp[v]
    var out: [8]V8 = @splat(@splat(0));
    for (tmp[0..n_rows], 0..) |t, v| {
        inline for (&out, 0..) |*o, y| o.* += @as(V8, @splat(BASIS_T[y][v])) * t;
    }
    var samples: [64]f32 = undefined;
    inline for (out, 0..) |o, y| samples[y * 8 ..][0..8].* = o;
    return samples;
}

/// `inverse` of a block whose only nonzero coefficient is the DC term: every
/// sample is C[0][y] * (F[0][0] * C[0][x]), and all of C[0] is the same constant.
pub fn inverseDc(dc: f32) f32 {
    const c0 = BASIS[0][0];
    return c0 * (dc * c0);
}

/// samples (row-major) -> coefficients (natural order)
pub fn forward(samples: *const [64]f32) [64]f32 {
    var tmp: [8]V8 = undefined;
    // rows: tmp[y] = sum_x f[y][x] * C[.][x]
    for (0..8) |y| {
        var acc: V8 = @splat(0);
        inline for (0..8) |x| acc += @as(V8, @splat(samples[y * 8 + x])) * BASIS_T[x];
        tmp[y] = acc;
    }
    // columns: F[v] = sum_y C[v][y] * tmp[y]
    var out: [64]f32 = undefined;
    for (0..8) |v| {
        var acc: V8 = @splat(0);
        inline for (0..8) |y| acc += @as(V8, @splat(BASIS[v][y])) * tmp[y];
        out[v * 8 ..][0..8].* = acc;
    }
    return out;
}

test "DCT round trip" {
    var block: [64]f32 = undefined;
    for (&block, 0..) |*b, i| b.* = @floatFromInt(@as(i32, @intCast((i * 37) % 255)) - 128);
    const back = inverse(&forward(&block));
    for (block, back) |a, b| try std.testing.expectApproxEqAbs(a, b, 1e-3);
}

test "DCT of a constant block has only DC" {
    var block: [64]f32 = @splat(42);
    const f = forward(&block);
    try std.testing.expectApproxEqAbs(@as(f32, 42 * 8), f[0], 1e-3);
    for (f[1..]) |c| try std.testing.expectApproxEqAbs(@as(f32, 0), c, 1e-3);
}

test "sparse inverse equals the dense matrix product exactly" {
    const dense = struct {
        fn inverse(coeffs: *const [64]f32) [64]f32 {
            var tmp: [8]V8 = undefined;
            for (0..8) |v| {
                var acc: V8 = @splat(0);
                inline for (0..8) |u| acc += @as(V8, @splat(coeffs[v * 8 + u])) * BASIS[u];
                tmp[v] = acc;
            }
            var out: [64]f32 = undefined;
            for (0..8) |y| {
                var acc: V8 = @splat(0);
                inline for (0..8) |v| acc += @as(V8, @splat(BASIS[v][y])) * tmp[v];
                out[y * 8 ..][0..8].* = acc;
            }
            return out;
        }
    };
    var prng: std.Random.DefaultPrng = .init(7);
    const random = prng.random();
    for (0..20_000) |i| {
        // dequantized coefficients: integers, mostly zero, denser in some blocks than others
        const density = random.uintLessThan(u32, 64) + 1;
        var block: [64]f32 = undefined;
        for (&block) |*c| {
            const q: i32 = random.intRangeAtMost(i32, 1, 255);
            const v: i32 = if (random.uintLessThan(u32, 64) < density) random.intRangeAtMost(i32, -1023, 1023) else 0;
            c.* = @floatFromInt(if (i % 2 == 0) v * q else v);
        }
        const a = dense.inverse(&block);
        const b = inverse(&block);
        for (a, b) |x, y| try std.testing.expect(x == y);
    }
}

test "DC-only shortcut equals the full inverse exactly" {
    // the range of dequantized DC values with 8-bit tables: all small ones, a sample of the rest
    var dc: i32 = -2048 * 255;
    while (dc <= 2048 * 255) : (dc += if (@abs(dc) > 4096) 97 else 1) {
        var block: [64]f32 = @splat(0);
        block[0] = @floatFromInt(dc);
        const full = inverse(&block);
        const v = inverseDc(block[0]);
        for (full) |s| try std.testing.expect(s == v);
    }
}
