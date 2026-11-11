//! VP8 YUV 4:2:0 -> RGB(A), matching libwebp's default output exactly:
//! "fancy" chroma upsampling (UpsampleRgbLinePair) and its fixed-point
//! BT.601 conversion (VP8YUVToR/G/B in src/dsp/yuv.h).
const std = @import("std");
const Planes = @import("vp8.zig").Planes;

/// Writes `planes` as rgb (3 bytes) or rgba (4 bytes, alpha from `alpha` or 255).
pub fn toRgb(planes: *const Planes, alpha: ?[]const u8, channels: usize, out: []u8) void {
    const w: usize = planes.width;
    const h: usize = planes.height;
    const ch = (h + 1) / 2; // chroma rows
    for (0..h) |y| {
        // libwebp pairs luma rows (2k-1, 2k) between chroma rows k-1 and k;
        // the first row, and the last row of an even-height image, use one row.
        const near, const far = if (y == 0)
            .{ 0, 0 }
        else if (y & 1 == 1)
            .{ (y - 1) / 2, if ((y + 1) / 2 < ch) (y + 1) / 2 else (y - 1) / 2 }
        else
            .{ y / 2, y / 2 - 1 };
        const u_near = planes.u[near * planes.uv_stride ..];
        const u_far = planes.u[far * planes.uv_stride ..];
        const v_near = planes.v[near * planes.uv_stride ..];
        const v_far = planes.v[far * planes.uv_stride ..];
        const y_row = planes.y[y * planes.y_stride ..];
        for (0..w) |x| {
            const u = upsample(u_near, u_far, x, w);
            const v = upsample(v_near, v_far, x, w);
            const luma: i32 = y_row[x];
            const px = out[(y * w + x) * channels ..];
            px[0] = clip8(mulHi(luma, 19077) + mulHi(v, 26149) - 14234);
            px[1] = clip8(mulHi(luma, 19077) - mulHi(u, 6419) - mulHi(v, 13320) + 8708);
            px[2] = clip8(mulHi(luma, 19077) + mulHi(u, 33050) - 17685);
            if (channels == 4) px[3] = if (alpha) |a| a[y * w + x] else 255;
        }
    }
}

/// Chroma at luma column `x` from the near and far chroma rows: weights
/// 9/3/3/1 with libwebp's two-step rounding, or 3/1 vertically at the edges.
fn upsample(near: []const u8, far: []const u8, x: usize, w: usize) i32 {
    const cw = (w + 1) / 2;
    var n: usize = undefined; // nearest chroma column
    var f: usize = undefined; // the other neighbouring column
    if (x == 0) {
        return (3 * @as(i32, near[0]) + far[0] + 2) >> 2;
    } else if (x & 1 == 1) {
        if ((x + 1) / 2 >= cw) { // last column of an even-width row
            const c = cw - 1;
            return (3 * @as(i32, near[c]) + far[c] + 2) >> 2;
        }
        n = (x - 1) / 2;
        f = (x + 1) / 2;
    } else {
        n = x / 2;
        f = x / 2 - 1;
    }
    const nn: i32 = near[n];
    const sum = nn + 3 * @as(i32, near[f]) + 3 * @as(i32, far[n]) + far[f] + 8;
    return ((sum >> 3) + nn) >> 1;
}

fn mulHi(v: i32, coeff: i32) i32 {
    return (v * coeff) >> 8;
}

/// 14-bit fixed point (YUV_FIX2 = 6) -> 0..255.
fn clip8(v: i32) u8 {
    const mask = (256 << 6) - 1;
    if (v & ~@as(i32, mask) == 0) return @intCast(v >> 6);
    return if (v < 0) 0 else 255;
}

test "gray is gray" {
    // Y=U=V=128 -> mid gray in every channel
    var y: [16 * 16]u8 = @splat(128);
    var u: [8 * 8]u8 = @splat(128);
    var v: [8 * 8]u8 = @splat(128);
    const p: Planes = .{ .width = 3, .height = 3, .y = &y, .u = &u, .v = &v, .y_stride = 16, .uv_stride = 8 };
    var out: [9 * 3]u8 = undefined;
    toRgb(&p, null, 3, &out);
    for (out) |c| try std.testing.expect(c >= 129 and c <= 131); // BT.601 limited range: 128 -> ~130
}
