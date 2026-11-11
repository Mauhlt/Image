//! Intra sample prediction (H.265 8.4.4.2).
const std = @import("std");
const Picture = @import("picture.zig").Picture;
const tables = @import("tables.zig");

pub const planar: u8 = 0;
pub const dc: u8 = 1;

/// Predicts the nTbS x nTbS block of component `c` at (x0, y0) (component
/// coordinates) with `mode` (0 planar, 1 DC, 2..34 angular) into the plane.
pub fn predict(pic: *Picture, c: usize, x0: usize, y0: usize, log2: u3, mode: u8) void {
    const n: usize = @as(usize, 1) << log2;
    const shift: u1 = if (c == 0) 0 else pic.chroma_shift;
    const bit_depth = if (c == 0) pic.sps.bit_depth_luma else pic.sps.bit_depth_chroma;
    const plane = pic.planes[c];
    const stride = pic.width[c];

    // Reference samples in substitution order (8.4.4.2.2):
    //   ref[0 .. 2n)      left column, bottom (y = 2n-1) to top (y = 0)
    //   ref[2n]           the corner (-1, -1)
    //   ref[2n+1 .. 4n+1) top row, x = 0 .. 2n-1
    var ref: [4 * 64 + 1]i32 = undefined;
    var avail: [4 * 64 + 1]bool = undefined;
    const total = 4 * n + 1;
    const xl: usize = x0 << shift; // current block in luma coordinates
    const yl: usize = y0 << shift;
    var any = false;
    for (0..total) |i| {
        const xn: isize, const yn: isize = if (i < 2 * n)
            .{ @as(isize, @intCast(x0)) - 1, @intCast(y0 + 2 * n - 1 - i) }
        else if (i == 2 * n)
            .{ @as(isize, @intCast(x0)) - 1, @as(isize, @intCast(y0)) - 1 }
        else
            .{ @intCast(x0 + i - 2 * n - 1), @as(isize, @intCast(y0)) - 1 };
        const ok = (xn < @as(isize, @intCast(pic.width[c])) and yn < @as(isize, @intCast(pic.height[c]))) and
            pic.available(xl, yl, xn << shift, yn << shift);
        avail[i] = ok;
        if (ok) {
            ref[i] = plane[@as(usize, @intCast(yn)) * stride + @as(usize, @intCast(xn))];
            any = true;
        }
    }
    if (!any) {
        @memset(ref[0..total], @as(i32, 1) << @intCast(bit_depth - 1));
    } else {
        // the first sample takes the first available one; the rest copy their predecessor
        if (!avail[0]) {
            for (1..total) |i| if (avail[i]) {
                ref[0] = ref[i];
                break;
            };
        }
        for (1..total) |i| if (!avail[i]) {
            ref[i] = ref[i - 1];
        };
    }

    // p(-1, y) = left(y), p(x, -1) = top(x), p(-1, -1) = corner
    var left: [2 * 64]i32 = undefined;
    var top: [2 * 64]i32 = undefined;
    for (0..2 * n) |i| {
        left[i] = ref[2 * n - 1 - i];
        top[i] = ref[2 * n + 1 + i];
    }
    var corner = ref[2 * n];

    // 8.4.4.2.3 filtering of the neighbouring samples (luma only in 4:2:0)
    if (c == 0 and mode != dc and n != 4) {
        const dist = @min(@abs(@as(i32, mode) - 26), @abs(@as(i32, mode) - 10));
        const threshold: u32 = switch (n) {
            8 => 7,
            16 => 1,
            else => 0,
        };
        if (mode == planar or dist > threshold) filterRefs(pic, n, bit_depth, &left, &top, &corner);
    }

    const max: i32 = (@as(i32, 1) << @intCast(bit_depth)) - 1;
    const log2n: u5 = log2;
    const in: i32 = @intCast(n);
    switch (mode) {
        planar => for (0..n) |y| for (0..n) |x| {
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);
            const v = (in - 1 - xi) * left[y] + (xi + 1) * top[n] + (in - 1 - yi) * top[x] + (yi + 1) * left[n] + in;
            plane[(y0 + y) * stride + x0 + x] = @intCast(v >> (log2n + 1));
        },
        dc => {
            var sum: i32 = in;
            for (0..n) |i| sum += left[i] + top[i];
            const v = sum >> (log2n + 1);
            for (0..n) |y| for (0..n) |x| {
                plane[(y0 + y) * stride + x0 + x] = @intCast(v);
            };
            if (c == 0 and n < 32) { // smooth the block's top row and left column
                plane[y0 * stride + x0] = @intCast((left[0] + 2 * v + top[0] + 2) >> 2);
                for (1..n) |x| plane[y0 * stride + x0 + x] = @intCast((top[x] + 3 * v + 2) >> 2);
                for (1..n) |y| plane[(y0 + y) * stride + x0] = @intCast((left[y] + 3 * v + 2) >> 2);
            }
        },
        else => angular(plane, stride, x0, y0, n, mode, &left, &top, corner, c == 0, max),
    }
}

/// [1 2 1] smoothing, or bilinear "strong intra smoothing" for flat 32x32 luma.
fn filterRefs(pic: *const Picture, n: usize, bit_depth: u5, left: *[128]i32, top: *[128]i32, corner: *i32) void {
    const last = 2 * n - 1;
    if (pic.sps.strong_intra_smoothing and n == 32) {
        const thr = @as(i32, 1) << @intCast(bit_depth - 5);
        if (@abs(corner.* + top[last] - 2 * top[n - 1]) < thr and @abs(corner.* + left[last] - 2 * left[n - 1]) < thr) {
            const c = corner.*;
            const tl = top[last];
            const ll = left[last];
            for (0..last) |i| {
                const ii: i32 = @intCast(i);
                top[i] = ((63 - ii) * c + (ii + 1) * tl + 32) >> 6;
                left[i] = ((63 - ii) * c + (ii + 1) * ll + 32) >> 6;
            }
            return;
        }
    }
    var fl: [128]i32 = undefined;
    var ft: [128]i32 = undefined;
    const fc = (left[0] + 2 * corner.* + top[0] + 2) >> 2;
    for (0..last) |i| {
        const pl = if (i == 0) corner.* else left[i - 1];
        const pt = if (i == 0) corner.* else top[i - 1];
        fl[i] = (pl + 2 * left[i] + left[i + 1] + 2) >> 2;
        ft[i] = (pt + 2 * top[i] + top[i + 1] + 2) >> 2;
    }
    fl[last] = left[last];
    ft[last] = top[last];
    @memcpy(left[0 .. 2 * n], fl[0 .. 2 * n]);
    @memcpy(top[0 .. 2 * n], ft[0 .. 2 * n]);
    corner.* = fc;
}

/// 8.4.4.2.6: modes 2..17 predict from the left column (horizontal-ish),
/// 18..34 from the top row; negative angles extend the main reference with
/// samples projected from the other side.
fn angular(plane: []u16, stride: usize, x0: usize, y0: usize, n: usize, mode: u8, left: *const [128]i32, top: *const [128]i32, corner: i32, luma: bool, max: i32) void {
    const angle = tables.intra_pred_angle[mode];
    const vertical = mode >= 18;
    const main = if (vertical) top else left; // along the prediction direction
    const side = if (vertical) left else top;
    // ref[k + n] = reference sample k, for k in -n .. 2n
    var ref_buf: [3 * 64 + 1]i32 = undefined;
    const ref = ref_buf[0..];
    const o = n; // offset of index 0
    ref[o] = corner;
    for (0..2 * n) |k| ref[o + 1 + k] = main[k];
    const in: i32 = @intCast(n);
    if (angle < 0 and (in * angle) >> 5 < -1) {
        const inv = tables.invAngle(mode);
        var k: i32 = (in * angle) >> 5;
        while (k <= -1) : (k += 1) {
            const s = ((k * inv + 128) >> 8) - 1; // index into the side reference
            ref[@intCast(@as(i32, @intCast(o)) + k)] = side[@intCast(s)];
        }
    }
    for (0..n) |j| { // j runs across the direction, i along it
        const jj: i32 = @intCast(j);
        const idx = ((jj + 1) * angle) >> 5;
        const fact = ((jj + 1) * angle) & 31;
        for (0..n) |i| {
            const base: usize = @intCast(@as(i32, @intCast(o + i)) + idx + 1);
            const v = if (fact != 0)
                ((32 - fact) * ref[base] + fact * ref[base + 1] + 16) >> 5
            else
                ref[base];
            const x = if (vertical) i else j;
            const y = if (vertical) j else i;
            plane[(y0 + y) * stride + x0 + x] = @intCast(v);
        }
    }
    // pure horizontal / vertical luma: adjust the first column / row by the gradient
    if (luma and n < 32) {
        if (mode == 26) {
            for (0..n) |y| plane[(y0 + y) * stride + x0] = @intCast(std.math.clamp(top[0] + ((left[y] - corner) >> 1), 0, max));
        } else if (mode == 10) {
            for (0..n) |x| plane[y0 * stride + x0 + x] = @intCast(std.math.clamp(left[0] + ((top[x] - corner) >> 1), 0, max));
        }
    }
}
