//! Residual coding (H.265 7.3.8.11 / 9.3.4.2), scaling (8.6.2-8.6.3) and the
//! inverse transforms (8.6.4).
const std = @import("std");
const cabac = @import("cabac.zig");
const tables = @import("tables.zig");
const ScalingList = @import("params.zig").ScalingList;

pub const Block = struct {
    log2: u3,
    /// 0 luma, 1 Cb, 2 Cr
    c: u2,
    /// intra prediction mode used for this block (selects the scan)
    pred_mode: u8,
    transform_skip_enabled: bool,
    sign_data_hiding: bool,
    bypass: bool, // cu_transquant_bypass
};

/// Parses the coefficients of one transform block into `coeffs` (raster,
/// n * n, zero-initialized by the caller). Returns whether transform skip is used.
pub fn parse(d: *cabac.Decoder, ctx: *cabac.Contexts, b: Block, coeffs: []i32) bool {
    const log2: u5 = b.log2;
    const n: usize = @as(usize, 1) << log2;
    const luma = b.c == 0;

    var transform_skip = false;
    if (b.transform_skip_enabled and !b.bypass and log2 == 2)
        transform_skip = d.decision(&ctx.transform_skip[@intFromBool(!luma)]) == 1;

    // last significant coefficient position
    var last_x = lastPrefix(d, &ctx.last_x_prefix, log2, luma);
    var last_y = lastPrefix(d, &ctx.last_y_prefix, log2, luma);
    last_x = lastSuffix(d, last_x);
    last_y = lastSuffix(d, last_y);

    // 7.4.9.11: mode-dependent scan for small intra blocks
    var scan: tables.ScanType = .diagonal;
    if (log2 == 2 or (log2 == 3 and luma)) {
        if (b.pred_mode >= 6 and b.pred_mode <= 14) scan = .vertical else if (b.pred_mode >= 22 and b.pred_mode <= 30) scan = .horizontal;
    }
    if (scan == .vertical) std.mem.swap(u32, &last_x, &last_y);

    const groups_log2 = log2 - 2; // coefficient groups per side, log2
    const gw: usize = @as(usize, 1) << @intCast(groups_log2);
    const group_scan: []const tables.Pos = switch (groups_log2) {
        0 => &tables.group_scan_1[@intFromEnum(scan)],
        1 => &tables.group_scan_2[@intFromEnum(scan)],
        2 => &tables.group_scan_4,
        else => &tables.group_scan_8,
    };
    const pos_scan = &tables.coeff_scan[@intFromEnum(scan)];

    // find the group and position of the last coefficient in scan order
    var last_group: usize = 0;
    var last_pos: usize = 0;
    find: for (group_scan, 0..) |g, gi| {
        if (g[0] != last_x >> 2 or g[1] != last_y >> 2) continue;
        for (pos_scan, 0..) |p, pi| {
            if (p[0] == (last_x & 3) and p[1] == (last_y & 3)) {
                last_group = gi;
                last_pos = pi;
                break :find;
            }
        }
    }

    var coded_group: [64]bool = @splat(false); // [y * gw + x]
    var greater1_state: u32 = 1; // "c1", carried between groups for the ctxSet

    var gi = last_group + 1;
    while (gi > 0) {
        gi -= 1;
        const gx: usize = group_scan[gi][0];
        const gy: usize = group_scan[gi][1];

        // neighbouring groups to the right and below, for contexts
        const right = gx + 1 < gw and coded_group[gy * gw + gx + 1];
        const below = gy + 1 < gw and coded_group[(gy + 1) * gw + gx];

        var infer_dc = false;
        var group_coded = true;
        if (gi < last_group and gi > 0) {
            const inc: usize = @intFromBool(right or below) + @as(usize, if (luma) 0 else 2);
            group_coded = d.decision(&ctx.coded_sub_block[inc]) == 1;
            infer_dc = true;
        }
        coded_group[gy * gw + gx] = group_coded;

        // significance flags, from the highest position down
        var sig_pos: [16]u8 = undefined; // positions (0..15) in scan order, descending
        var n_sig: usize = 0;
        if (gi == last_group) {
            sig_pos[0] = @intCast(last_pos);
            n_sig = 1;
        }
        const prev_csbf: u2 = @as(u2, @intFromBool(right)) | (@as(u2, @intFromBool(below)) << 1);
        if (group_coded) {
            var p = if (gi == last_group) last_pos else 16;
            while (p > 0) {
                p -= 1;
                const xc = (gx << 2) + pos_scan[p][0];
                const yc = (gy << 2) + pos_scan[p][1];
                var sig: bool = undefined;
                if (p == 0 and infer_dc) {
                    sig = true;
                } else {
                    const inc = sigCtx(log2, b.c, xc, yc, prev_csbf, gx == 0 and gy == 0, scan);
                    sig = d.decision(&ctx.sig_coeff[inc]) == 1;
                    if (sig) infer_dc = false;
                }
                if (sig) {
                    sig_pos[n_sig] = @intCast(p);
                    n_sig += 1;
                }
            }
        }
        if (n_sig == 0) continue;

        // greater-than-1 / greater-than-2 flags (9.3.4.2.6 / 9.3.4.2.7)
        var ctx_set: usize = if (gi == 0 or !luma) 0 else 2;
        if (greater1_state == 0) ctx_set += 1;
        greater1_state = 1;
        var greater1: [16]bool = @splat(false);
        var first_g1: ?usize = null;
        for (0..@min(n_sig, 8)) |k| {
            const inc = ctx_set * 4 + greater1_state + @as(usize, if (luma) 0 else 16);
            greater1[k] = d.decision(&ctx.greater1[inc]) == 1;
            if (greater1[k]) {
                greater1_state = 0;
                if (first_g1 == null) first_g1 = k;
            } else if (greater1_state > 0 and greater1_state < 3) {
                greater1_state += 1;
            }
        }
        var greater2 = false;
        if (first_g1 != null) greater2 = d.decision(&ctx.greater2[ctx_set + @as(usize, if (luma) 0 else 4)]) == 1;

        // signs (the last one may be hidden in the parity of the levels)
        const hidden = b.sign_data_hiding and !b.bypass and sig_pos[0] - sig_pos[n_sig - 1] > 3;
        const n_signs = if (hidden) n_sig - 1 else n_sig;
        const signs = d.bypassBits(@intCast(n_signs)) << @intCast(32 - n_signs);

        // remaining absolute levels
        var rice: u5 = 0;
        var sum: i32 = 0;
        for (0..n_sig) |k| {
            var base: i32 = 1;
            if (k < 8) {
                base += @intFromBool(greater1[k]);
                if (first_g1 == k) base += @intFromBool(greater2);
            }
            const threshold: i32 = if (k < 8) (if (first_g1 == k) 3 else 2) else 1;
            var level = base;
            if (base == threshold) {
                const rem: i32 = @intCast(remaining(d, rice));
                level += rem;
                if (level > 3 * (@as(i32, 1) << rice)) rice = @min(rice + 1, 4);
            }
            sum += level;
            const negative = if (k < n_signs) (signs >> @intCast(31 - k)) & 1 == 1 else (sum & 1 == 1);
            const p = sig_pos[k];
            const x = (gx << 2) + pos_scan[p][0];
            const y = (gy << 2) + pos_scan[p][1];
            coeffs[y * n + x] = if (negative) -level else level;
        }
    }
    return transform_skip;
}

/// last_sig_coeff_{x,y}_prefix: truncated unary with size-dependent contexts.
fn lastPrefix(d: *cabac.Decoder, ctx: *[18]u8, log2: u5, luma: bool) u32 {
    const offset: u32 = if (luma) 3 * (log2 - 2) + ((log2 - 1) >> 2) else 15;
    const shift: u5 = if (luma) (log2 + 1) >> 2 else log2 - 2;
    const max: u32 = (@as(u32, log2) << 1) - 1;
    var v: u32 = 0;
    while (v < max and d.decision(&ctx[offset + (v >> shift)]) == 1) v += 1;
    return v;
}

fn lastSuffix(d: *cabac.Decoder, prefix: u32) u32 {
    if (prefix <= 3) return prefix;
    const bits: u5 = @intCast((prefix >> 1) - 1);
    return (@as(u32, 1) << bits) * (2 + (prefix & 1)) + d.bypassBits(bits);
}

/// 9.3.4.2.5: context of sig_coeff_flag at (xc, yc).
fn sigCtx(log2: u5, c: u2, xc: usize, yc: usize, prev_csbf: u2, first_group: bool, scan: tables.ScanType) usize {
    const map = [16]u8{ 0, 1, 4, 5, 2, 3, 4, 5, 6, 6, 8, 8, 7, 7, 8, 8 };
    var s: usize = undefined;
    if (log2 == 2) {
        s = map[(yc << 2) + xc];
    } else if (xc + yc == 0) {
        s = 0;
    } else {
        const xp = xc & 3;
        const yp = yc & 3;
        s = switch (prev_csbf) {
            0 => if (xp + yp == 0) 2 else if (xp + yp < 3) 1 else 0,
            1 => if (yp == 0) 2 else if (yp == 1) 1 else 0,
            2 => if (xp == 0) 2 else if (xp == 1) 1 else 0,
            3 => 2,
        };
        if (c == 0) {
            if (!first_group) s += 3;
            s += if (log2 == 3) (if (scan == .diagonal) @as(usize, 9) else 15) else 21;
        } else {
            s += if (log2 == 3) @as(usize, 9) else 12;
        }
    }
    return if (c == 0) s else 27 + s;
}

/// coeff_abs_level_remaining (9.3.3.11): Rice prefix, Exp-Golomb escape.
fn remaining(d: *cabac.Decoder, rice: u5) u32 {
    var prefix: u32 = 0;
    while (prefix < 32 and d.bypass() == 1) prefix += 1;
    if (prefix <= 3) return (prefix << rice) + d.bypassBits(rice);
    const extra: u5 = @intCast(@min(prefix - 3 + rice, 31));
    return ((((@as(u32, 1) << @intCast(prefix - 3)) + 3 - 1) << rice)) + d.bypassBits(extra);
}

/// 8.6.2 / 8.6.3: scales coefficient levels in place.
pub fn dequantize(coeffs: []i32, log2: u3, qp: i32, bit_depth: u5, scaling: ?*const ScalingList, matrix: usize) void {
    const n: usize = @as(usize, 1) << log2;
    const bd_shift: u6 = @intCast(@as(i32, bit_depth) + @as(i32, log2) - 5);
    const scale: i64 = tables.level_scale[@intCast(@mod(qp, 6))] << @intCast(@divFloor(qp, 6));
    const round: i64 = @as(i64, 1) << (bd_shift - 1);
    for (0..n) |y| for (0..n) |x| {
        const level = coeffs[y * n + x];
        if (level == 0) continue;
        const m: i64 = if (scaling) |s| s.factor(log2, matrix, x, y) else 16;
        const v = (@as(i64, level) * m * scale + round) >> bd_shift;
        coeffs[y * n + x] = @intCast(std.math.clamp(v, -32768, 32767));
    };
}

/// 8.6.4: residual samples from scaled coefficients (in place).
pub fn inverseTransform(coeffs: []i32, log2: u3, bit_depth: u5, dst: bool, transform_skip: bool) void {
    const n: usize = @as(usize, 1) << log2;
    const bd_shift: u5 = @intCast(20 - @as(i32, bit_depth));
    const round: i32 = @as(i32, 1) << (bd_shift - 1);
    if (transform_skip) {
        for (coeffs[0 .. n * n]) |*v| v.* = ((v.* << 7) + round) >> bd_shift;
        return;
    }
    var tmp: [32 * 32]i32 = undefined;
    // columns: e = M^T * d, then clip (e + 64) >> 7 to 16 bits
    for (0..n) |x| {
        var col: [32]i32 = undefined;
        for (0..n) |y| col[y] = coeffs[y * n + x];
        var out: [32]i32 = undefined;
        transform1d(col[0..n], out[0..n], dst);
        for (0..n) |y| tmp[y * n + x] = std.math.clamp((out[y] + 64) >> 7, -32768, 32767);
    }
    // rows, then the final rounding shift
    for (0..n) |y| {
        var out: [32]i32 = undefined;
        transform1d(tmp[y * n ..][0..n], out[0..n], dst);
        for (0..n) |x| coeffs[y * n + x] = (out[x] + round) >> bd_shift;
    }
}

/// y[i] = sum_j M[j][i] * x[j]
fn transform1d(in: []const i32, out: []i32, dst: bool) void {
    const n = in.len;
    if (dst) {
        for (0..4) |i| {
            var s: i32 = 0;
            for (0..4) |j| s += tables.dst4[j][i] * in[j];
            out[i] = s;
        }
        return;
    }
    const step = 32 / n; // row k of the n-point DCT is row k * 32 / n of the 32-point one
    for (0..n) |i| {
        var s: i32 = 0;
        for (0..n) |j| {
            if (in[j] != 0) s += @as(i32, tables.dct32[j * step][i]) * in[j];
        }
        out[i] = s;
    }
}

test "inverse DCT of a DC coefficient is flat" {
    var c: [16]i32 = @splat(0);
    c[0] = 64; // after scaling
    inverseTransform(&c, 2, 8, false, false);
    for (c[1..]) |v| try std.testing.expectEqual(c[0], v);
}
