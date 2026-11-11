//! Constant tables of H.265. Where the spec defines a table by a procedure
//! (scan orders, the transform matrix) it is generated at compile time.
//! CABAC and filter tables match the spec (cross-checked against Kvazaar, BSD).

/// A position in a block: x, y.
pub const Pos = [2]u8;

pub const ScanType = enum(u2) { diagonal, horizontal, vertical };

/// 6.5.3 up-right diagonal, 6.5.4 horizontal, 6.5.5 vertical scan of an n x n block.
pub fn scanOrder(comptime n: usize, comptime t: ScanType) [n * n]Pos {
    var out: [n * n]Pos = undefined;
    @setEvalBranchQuota(10_000);
    switch (t) {
        .diagonal => {
            var i: usize = 0;
            var x: isize = 0;
            var y: isize = 0;
            while (i < n * n) {
                while (y >= 0) {
                    if (x < n and y < n) {
                        out[i] = .{ @intCast(x), @intCast(y) };
                        i += 1;
                    }
                    y -= 1;
                    x += 1;
                }
                y = x;
                x = 0;
            }
        },
        .horizontal => for (0..n) |y| for (0..n) |x| {
            out[y * n + x] = .{ @intCast(x), @intCast(y) };
        },
        .vertical => for (0..n) |x| for (0..n) |y| {
            out[x * n + y] = .{ @intCast(x), @intCast(y) };
        },
    }
    return out;
}

pub const diag4x4 = scanOrder(4, .diagonal);
pub const diag8x8 = scanOrder(8, .diagonal);

/// [scan type] positions inside a 4x4 coefficient group.
pub const coeff_scan = [3][16]Pos{ scanOrder(4, .diagonal), scanOrder(4, .horizontal), scanOrder(4, .vertical) };

/// Sub-block (coefficient group) scans for TUs of 4, 8, 16, 32: [log2 size - 2][scan type].
/// Horizontal / vertical only occur for 4x4 and 8x8 TUs; the larger ones use diagonal.
pub const group_scan_1 = [3][1]Pos{ .{.{ 0, 0 }}, .{.{ 0, 0 }}, .{.{ 0, 0 }} };
pub const group_scan_2 = [3][4]Pos{ scanOrder(2, .diagonal), scanOrder(2, .horizontal), scanOrder(2, .vertical) };
pub const group_scan_4 = scanOrder(4, .diagonal);
pub const group_scan_8 = scanOrder(8, .diagonal);

/// Table 7-6: default 8x8 scaling lists, in up-right diagonal order.
pub const default_scaling_intra = [64]u8{
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 16, 17, 16, 17, 18,
    17, 18, 18, 17, 18, 21, 19, 20, 21, 20, 19, 21, 24, 22, 22, 24,
    24, 22, 22, 24, 25, 25, 27, 30, 27, 25, 25, 29, 31, 35, 35, 31,
    29, 36, 41, 44, 41, 36, 47, 54, 54, 47, 65, 70, 65, 88, 88, 115,
};
pub const default_scaling_inter = [64]u8{
    16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 17, 17, 17, 17, 17, 18,
    18, 18, 18, 18, 18, 20, 20, 20, 20, 20, 20, 20, 24, 24, 24, 24,
    24, 24, 24, 24, 25, 25, 25, 25, 25, 25, 25, 28, 28, 28, 28, 28,
    28, 33, 33, 33, 33, 33, 41, 41, 41, 41, 54, 54, 54, 71, 71, 91,
};

/// 8.6.3: dequantization scale per qP % 6.
pub const level_scale = [6]i32{ 40, 45, 51, 57, 64, 72 };

/// Table 8-10 (ChromaArrayType 1): QpC for qPi 30..43; below 30 QpC = qPi, above 43 QpC = qPi - 6.
pub fn chromaQp(qpi: i32) i32 {
    const mid = [14]i32{ 29, 30, 31, 32, 33, 33, 34, 34, 35, 35, 36, 36, 37, 37 };
    if (qpi < 30) return qpi;
    if (qpi > 43) return qpi - 6;
    return mid[@intCast(qpi - 30)];
}

/// Table 8-4: intraPredAngle for angular modes 2..34 (indices 0, 1 unused).
pub const intra_pred_angle = [35]i32{
    0,   0,   32,  26,  21,  17,  13,  9,   5,   2,   0,   -2,  -5,  -9, -13, -17, -21, -26,
    -32, -26, -21, -17, -13, -9,  -5,  -2,  0,   2,   5,   9,   13,  17, 21,  26,  32,
};
/// Table 8-5: invAngle for modes 11..25.
pub fn invAngle(mode: u8) i32 {
    const t = [15]i32{ -4096, -1638, -910, -630, -482, -390, -315, -256, -315, -390, -482, -630, -910, -1638, -4096 };
    return t[mode - 11];
}

/// 8.6.4.2: the 32x32 DCT matrix, transMatrix[k][n] (k = frequency, n = sample).
/// Every entry is +-(one of 31 values) of 64*sqrt(2)*cos(pi*k*(2n+1)/64), rounded
/// as the spec does; smaller transforms use rows k * 32 / N and the first N columns.
pub const dct32 = blk: {
    // amplitudes for angles i * pi / 64, i = 1..31 (odd i, then i = 2 mod 4, ...)
    const odd32 = [16]i32{ 90, 90, 88, 85, 82, 78, 73, 67, 61, 54, 46, 38, 31, 22, 13, 4 };
    const odd16 = [8]i32{ 90, 87, 80, 70, 57, 43, 25, 9 };
    const odd8 = [4]i32{ 89, 75, 50, 18 };
    const odd4 = [2]i32{ 83, 36 };
    var amp: [33]i32 = undefined;
    for (1..32) |i| {
        amp[i] = if (i % 2 == 1) odd32[(i - 1) / 2] else if (i % 4 == 2) odd16[(i - 2) / 4] else if (i % 8 == 4) odd8[(i - 4) / 8] else if (i % 16 == 8) odd4[(i - 8) / 16] else 64;
    }
    amp[32] = 0;
    var m: [32][32]i8 = undefined;
    @setEvalBranchQuota(100_000);
    for (0..32) |k| for (0..32) |n| {
        if (k == 0) {
            m[k][n] = 64;
            continue;
        }
        var a = (k * (2 * n + 1)) % 128; // angle in units of pi / 64, mod 2 pi
        if (a > 64) a = 128 - a; // cos is even around pi
        const v: i32 = if (a > 32) -amp[64 - a] else amp[a];
        m[k][n] = @intCast(v);
    };
    break :blk m;
};

/// 8.6.4.2: 4x4 DST-VII for intra luma 4x4 blocks.
pub const dst4 = [4][4]i32{
    .{ 29, 55, 74, 84 },
    .{ 74, 74, 0, -74 },
    .{ 84, -29, -74, 55 },
    .{ 55, -84, 74, -29 },
};

/// Table 8-12: deblocking thresholds, indexed by Q.
pub const beta_table = [52]u8{
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
    16, 17, 18, 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 40, 42, 44, 46, 48, 50, 52, 54, 56, 58, 60, 62, 64,
};
pub const tc_table = [54]u8{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  0,  1,  1,  1,  1,  1,  1,  1,  1,  1,
    2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 5, 5, 6, 6, 7, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 24,
};

/// Table 9-46: CABAC LPS range, [pStateIdx][(ivlCurrRange >> 6) & 3].
pub const range_lps = [64][4]u8{
    .{ 128, 176, 208, 240 }, .{ 128, 167, 197, 227 }, .{ 128, 158, 187, 216 }, .{ 123, 150, 178, 205 },
    .{ 116, 142, 169, 195 }, .{ 111, 135, 160, 185 }, .{ 105, 128, 152, 175 }, .{ 100, 122, 144, 166 },
    .{ 95, 116, 137, 158 },  .{ 90, 110, 130, 150 },  .{ 85, 104, 123, 142 },  .{ 81, 99, 117, 135 },
    .{ 77, 94, 111, 128 },   .{ 73, 89, 105, 122 },   .{ 69, 85, 100, 116 },   .{ 66, 80, 95, 110 },
    .{ 62, 76, 90, 104 },    .{ 59, 72, 86, 99 },     .{ 56, 69, 81, 94 },     .{ 53, 65, 77, 89 },
    .{ 51, 62, 73, 85 },     .{ 48, 59, 69, 80 },     .{ 46, 56, 66, 76 },     .{ 43, 53, 63, 72 },
    .{ 41, 50, 59, 69 },     .{ 39, 48, 56, 65 },     .{ 37, 45, 54, 62 },     .{ 35, 43, 51, 59 },
    .{ 33, 41, 48, 56 },     .{ 32, 39, 46, 53 },     .{ 30, 37, 43, 50 },     .{ 29, 35, 41, 48 },
    .{ 27, 33, 39, 45 },     .{ 26, 31, 37, 43 },     .{ 24, 30, 35, 41 },     .{ 23, 28, 33, 39 },
    .{ 22, 27, 32, 37 },     .{ 21, 26, 30, 35 },     .{ 20, 24, 29, 33 },     .{ 19, 23, 27, 31 },
    .{ 18, 22, 26, 30 },     .{ 17, 21, 25, 28 },     .{ 16, 20, 23, 27 },     .{ 15, 19, 22, 25 },
    .{ 14, 18, 21, 24 },     .{ 14, 17, 20, 23 },     .{ 13, 16, 19, 22 },     .{ 12, 15, 18, 21 },
    .{ 12, 14, 17, 20 },     .{ 11, 14, 16, 19 },     .{ 11, 13, 15, 18 },     .{ 10, 12, 15, 17 },
    .{ 10, 12, 14, 16 },     .{ 9, 11, 13, 15 },      .{ 9, 11, 12, 14 },      .{ 8, 10, 12, 14 },
    .{ 8, 9, 11, 13 },       .{ 7, 9, 11, 12 },       .{ 7, 9, 10, 12 },       .{ 7, 8, 10, 11 },
    .{ 6, 8, 9, 11 },        .{ 6, 7, 9, 10 },        .{ 6, 7, 8, 9 },         .{ 2, 2, 2, 2 },
};
/// Table 9-47: state after an LPS. After an MPS it is min(state + 1, 62).
pub const trans_lps = [64]u8{
    0,  0,  1,  2,  2,  4,  4,  5,  6,  7,  8,  9,  9,  11, 11, 12, 13, 13, 15, 15, 16, 16,
    18, 18, 19, 19, 21, 21, 22, 22, 23, 24, 24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30,
    31, 32, 32, 33, 33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63,
};

const std = @import("std");

test "dct matrix spot checks against the spec" {
    // 4-point rows live at 32-point rows 0, 8, 16, 24
    try std.testing.expectEqual([4]i8{ 83, 36, -36, -83 }, dct32[8][0..4].*);
    try std.testing.expectEqual([4]i8{ 64, -64, -64, 64 }, dct32[16][0..4].*);
    try std.testing.expectEqual([4]i8{ 36, -83, 83, -36 }, dct32[24][0..4].*);
    // 8-point row 1 = 32-point row 4
    try std.testing.expectEqual([8]i8{ 89, 75, 50, 18, -18, -50, -75, -89 }, dct32[4][0..8].*);
    // 16-point row 1 = 32-point row 2
    try std.testing.expectEqual([8]i8{ 90, 87, 80, 70, 57, 43, 25, 9 }, dct32[2][0..8].*);
    // 32-point row 1 and its antisymmetry
    try std.testing.expectEqual(@as(i8, 90), dct32[1][0]);
    try std.testing.expectEqual(@as(i8, 4), dct32[1][15]);
    try std.testing.expectEqual(@as(i8, -4), dct32[1][16]);
    try std.testing.expectEqual(@as(i8, -90), dct32[1][31]);
    // row 31: 4 -13 22 -31 ...
    try std.testing.expectEqual([4]i8{ 4, -13, 22, -31 }, dct32[31][0..4].*);
}

test "diagonal scan" {
    try std.testing.expectEqual(Pos{ 0, 0 }, diag4x4[0]);
    try std.testing.expectEqual(Pos{ 0, 1 }, diag4x4[1]);
    try std.testing.expectEqual(Pos{ 1, 0 }, diag4x4[2]);
    try std.testing.expectEqual(Pos{ 0, 2 }, diag4x4[3]);
    try std.testing.expectEqual(Pos{ 3, 3 }, diag4x4[15]);
}
