//! VP8 YUV 4:2:0 -> RGB(A), matching libwebp's default output exactly:
//! "fancy" chroma upsampling (UpsampleRgbLinePair) and its fixed-point
//! BT.601 conversion (VP8YUVToR/G/B in src/dsp/yuv.h).
//!
//! Each output row is done in two passes over 16 pixels at a time: upsample
//! the U and V rows to full width, then convert. The arithmetic is generic
//! over the vector length, so the leftover pixels of a row run the very same
//! code with one lane.
const std = @import("std");
const Planes = @import("vp8.zig").Planes;

const lanes = 16;
/// Widest row a VP8 frame can have (14-bit dimensions).
const max_width = 1 << 14;

/// Writes `planes` as rgb (3 bytes) or rgba (4 bytes, alpha from `alpha` or 255).
pub fn toRgb(planes: *const Planes, alpha: ?[]const u8, channels: usize, out: []u8) void {
    const w: usize = planes.width;
    const h: usize = planes.height;
    const ch = (h + 1) / 2; // chroma rows
    var u_up: [max_width]u8 = undefined;
    var v_up: [max_width]u8 = undefined;
    for (0..h) |y| {
        // libwebp pairs luma rows (2k-1, 2k) between chroma rows k-1 and k;
        // the first row, and the last row of an even-height image, use one row.
        const near, const far = if (y == 0)
            .{ 0, 0 }
        else if (y & 1 == 1)
            .{ (y - 1) / 2, if ((y + 1) / 2 < ch) (y + 1) / 2 else (y - 1) / 2 }
        else
            .{ y / 2, y / 2 - 1 };
        const cs = planes.uv_stride;
        upsampleRow(planes.u[near * cs ..], planes.u[far * cs ..], u_up[0..w]);
        upsampleRow(planes.v[near * cs ..], planes.v[far * cs ..], v_up[0..w]);
        const y_row = planes.y[y * planes.y_stride ..][0..w];
        const a_row = if (alpha) |a| a[y * w ..][0..w] else null;
        const o = out[y * w * channels ..][0 .. w * channels];
        switch (channels) {
            inline 3, 4 => |c| convertRow(c, y_row, &u_up, &v_up, a_row, o),
            else => unreachable,
        }
    }
}

/// Chroma for each luma column from the near and far chroma rows: weights
/// 9/3/3/1 with libwebp's two-step rounding, or 3/1 vertically at the left
/// edge and at the right edge of an even-width row.
fn upsampleRow(near: []const u8, far: []const u8, out: []u8) void {
    const w = out.len;
    const cw = (w + 1) / 2;
    out[0] = edge(near[0], far[0]);
    if (w % 2 == 0) out[w - 1] = edge(near[cw - 1], far[cw - 1]);
    // chroma columns k and k + 1 give luma columns 2k + 1 (nearer k) and 2k + 2
    var k: usize = 0;
    while (k + lanes < cw) : (k += lanes) upsamplePairs(lanes, near, far, k, out);
    while (k + 1 < cw) : (k += 1) upsamplePairs(1, near, far, k, out);
}

fn edge(near: u8, far: u8) u8 {
    return @intCast((3 * @as(u16, near) + far + 2) >> 2);
}

fn upsamplePairs(comptime n: usize, near: []const u8, far: []const u8, k: usize, out: []u8) void {
    const V = @Vector(n, u16);
    const a: V = near[k..][0..n].*;
    const b: V = near[k + 1 ..][0..n].*;
    const c: V = far[k..][0..n].*;
    const d: V = far[k + 1 ..][0..n].*;
    out[2 * k + 1 ..][0 .. 2 * n].* = interleave(n, diagonal(n, a, b, c, d), diagonal(n, b, a, d, c));
}

/// The upsampled value nearest chroma sample `nn`: (9nn + 3nf + 3fn + ff) / 16
/// computed as libwebp does, ((nn + 3nf + 3fn + ff + 8) / 8 + nn) / 2.
fn diagonal(comptime n: usize, nn: @Vector(n, u16), nf: @Vector(n, u16), fnn: @Vector(n, u16), ff: @Vector(n, u16)) @Vector(n, u8) {
    const V = @Vector(n, u16);
    const three: V = @splat(3);
    const sum = nn + three * nf + three * fnn + ff + @as(V, @splat(8));
    return @intCast(((sum >> @splat(3)) + nn) >> @splat(1));
}

fn interleave(comptime n: usize, a: @Vector(n, u8), b: @Vector(n, u8)) [2 * n]u8 {
    const mask = comptime blk: {
        var m: [2 * n]i32 = undefined;
        for (0..n) |i| {
            m[2 * i] = i;
            m[2 * i + 1] = ~@as(i32, i);
        }
        break :blk m;
    };
    return @shuffle(u8, a, b, mask);
}

fn convertRow(comptime channels: usize, y: []const u8, u: []const u8, v: []const u8, alpha: ?[]const u8, out: []u8) void {
    var x: usize = 0;
    while (x + lanes <= y.len) : (x += lanes) convert(lanes, channels, y, u, v, alpha, x, out);
    while (x < y.len) : (x += 1) convert(1, channels, y, u, v, alpha, x, out);
}

/// libwebp's VP8YUVToR/G/B: 14-bit fixed point (YUV_FIX2 = 6), then clipped.
/// All in u16 lanes: each sum's positive part fits, and saturating
/// subtraction turns a negative result into 0, which clips to 0 as well.
fn convert(comptime n: usize, comptime channels: usize, y: []const u8, u: []const u8, v: []const u8, alpha: ?[]const u8, x: usize, out: []u8) void {
    const V = @Vector(n, u16);
    const luma = mulHi(n, y[x..][0..n].*, 19077);
    const cu: V = u[x..][0..n].*;
    const cv: V = v[x..][0..n].*;
    const r = clip8(n, (luma + mulHi(n, cv, 26149)) -| @as(V, @splat(14234)));
    const g = clip8(n, (luma + @as(V, @splat(8708))) -| (mulHi(n, cu, 6419) + mulHi(n, cv, 13320)));
    const b = clip8(n, (luma + mulHi(n, cu, 33050)) -| @as(V, @splat(17685)));
    const rg = @shuffle(u8, r, g, concatMask(n, n));
    const px = out[x * channels ..][0 .. n * channels];
    if (channels == 4) {
        const a: @Vector(n, u8) = if (alpha) |al| al[x..][0..n].* else @splat(255);
        const ba = @shuffle(u8, b, a, concatMask(n, n));
        px.* = @shuffle(u8, rg, ba, channelMask(n, 4));
    } else {
        px.* = @shuffle(u8, rg, b, channelMask(n, 3));
    }
}

/// (v * coeff) >> 8 for v <= 255, as the high half of (v << 8) * coeff: one
/// pmulhuw on x86.
fn mulHi(comptime n: usize, v: @Vector(n, u16), comptime coeff: u16) @Vector(n, u16) {
    const W = @Vector(n, u32);
    return @truncate((@as(W, v << @splat(8)) * @as(W, @splat(coeff))) >> @splat(16));
}

fn clip8(comptime n: usize, v: @Vector(n, u16)) @Vector(n, u8) {
    // with a comptime-known bound, @min already narrows the type to u8
    return @min(v >> @splat(6), @as(@Vector(n, u16), @splat(255)));
}

/// Shuffle mask that concatenates two vectors of `a` and `b` elements.
fn concatMask(comptime a: usize, comptime b: usize) [a + b]i32 {
    var m: [a + b]i32 = undefined;
    for (0..a) |i| m[i] = i;
    for (0..b) |i| m[a + i] = ~@as(i32, i);
    return m;
}

/// Interleaves channel planes into pixels. The first operand holds r ++ g;
/// the second b (rgb) or b ++ a (rgba).
fn channelMask(comptime n: usize, comptime channels: usize) [n * channels]i32 {
    var m: [n * channels]i32 = undefined;
    for (0..n) |i| for (0..channels) |c| {
        m[i * channels + c] = if (c < 2) c * n + i else ~@as(i32, (c - 2) * n + i);
    };
    return m;
}

test "rows match libwebp's per-pixel formulas at every width" {
    // the scalar definitions: chroma upsampled per luma pixel, i32 arithmetic
    const ref = struct {
        fn upsample(near: []const u8, far: []const u8, x: usize, w: usize) i32 {
            const cw = (w + 1) / 2;
            if (x == 0) return (3 * @as(i32, near[0]) + far[0] + 2) >> 2;
            if (x & 1 == 1 and (x + 1) / 2 >= cw) return (3 * @as(i32, near[cw - 1]) + far[cw - 1] + 2) >> 2;
            const n = if (x & 1 == 1) (x - 1) / 2 else x / 2; // nearest chroma column
            const f = if (x & 1 == 1) (x + 1) / 2 else x / 2 - 1;
            const nn: i32 = near[n];
            return (((nn + 3 * @as(i32, near[f]) + 3 * @as(i32, far[n]) + far[f] + 8) >> 3) + nn) >> 1;
        }
        fn clip(v: i32) u8 {
            return @intCast(std.math.clamp(v >> 6, 0, 255));
        }
    };
    var prng: std.Random.DefaultPrng = .init(4);
    const rand = prng.random();
    var y: [48 * 3]u8 = undefined;
    var u: [24 * 2]u8 = undefined;
    var v: [24 * 2]u8 = undefined;
    for (&y) |*p| p.* = rand.int(u8);
    for (&u) |*p| p.* = rand.int(u8);
    for (&v) |*p| p.* = rand.int(u8);
    var out: [48 * 3 * 4]u8 = undefined;
    // the near and far chroma rows of luma rows 0, 1, 2
    const chroma_rows = [3][2]usize{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 } };
    for (1..41) |w| {
        const p: Planes = .{ .width = @intCast(w), .height = 3, .y = &y, .u = &u, .v = &v, .y_stride = 48, .uv_stride = 24 };
        toRgb(&p, null, 4, out[0 .. w * 3 * 4]);
        for (chroma_rows, 0..) |nf, row| for (0..w) |x| {
            const cu = ref.upsample(u[nf[0] * 24 ..], u[nf[1] * 24 ..], x, w);
            const cv = ref.upsample(v[nf[0] * 24 ..], v[nf[1] * 24 ..], x, w);
            const luma = (@as(i32, y[row * 48 + x]) * 19077) >> 8;
            const want = [4]u8{
                ref.clip(luma + ((cv * 26149) >> 8) - 14234),
                ref.clip(luma - ((cu * 6419) >> 8) - ((cv * 13320) >> 8) + 8708),
                ref.clip(luma + ((cu * 33050) >> 8) - 17685),
                255,
            };
            try std.testing.expectEqualSlices(u8, &want, out[(row * w + x) * 4 ..][0..4]);
        };
    }
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
