//! VP8L transforms. Pixels are ARGB packed in u32 (A in the top byte).
const std = @import("std");
const Error = @import("../error.zig").Error;

pub const Type = enum(u2) {
    predictor = 0,
    cross_color = 1,
    subtract_green = 2,
    color_indexing = 3,
};

pub const Transform = struct {
    type: Type,
    /// width of the image this transform applies to (before color-index packing)
    xsize: usize,
    size_bits: u5 = 0,
    /// predictor / cross-color: block image; color-indexing: palette
    data: []u32 = &.{},
};

pub inline fn divRoundUp(a: usize, bits: u5) usize {
    return (a + (@as(usize, 1) << bits) - 1) >> bits;
}

// ── per-channel helpers ──

inline fn ch(p: u32, comptime shift: u5) i32 {
    return @intCast((p >> shift) & 0xFF);
}

inline fn average2(a: u32, b: u32) u32 {
    // per-byte (a + b) / 2 without overflow between lanes
    return (((a ^ b) & 0xFEFEFEFE) >> 1) + (a & b);
}

fn select(l: u32, t: u32, tl: u32) u32 {
    var pl: i32 = 0;
    var pt: i32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |s| {
        const p = ch(l, s) + ch(t, s) - ch(tl, s);
        pl += @intCast(@abs(p - ch(l, s)));
        pt += @intCast(@abs(p - ch(t, s)));
    }
    return if (pl < pt) l else t;
}

inline fn clamp255(v: i32) u32 {
    return @intCast(@min(@max(v, 0), 255));
}

fn clampAddSubtractFull(a: u32, b: u32, c: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |s| out |= clamp255(ch(a, s) + ch(b, s) - ch(c, s)) << s;
    return out;
}

fn clampAddSubtractHalf(a: u32, b: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |s| out |= clamp255(ch(a, s) + @divTrunc(ch(a, s) - ch(b, s), 2)) << s;
    return out;
}

/// Predictor `mode` for pixel `pos` (x > 0, y > 0) of an image `width` wide.
pub inline fn predict(mode: u4, px: []const u32, pos: usize, width: usize) u32 {
    const l = px[pos - 1];
    const t = px[pos - width];
    const tr = px[pos - width + 1]; // for the last column this is the row's first pixel
    const tl = px[pos - width - 1];
    return switch (mode) {
        0 => 0xFF000000,
        1 => l,
        2 => t,
        3 => tr,
        4 => tl,
        5 => average2(average2(l, tr), t),
        6 => average2(l, tl),
        7 => average2(l, t),
        8 => average2(tl, t),
        9 => average2(t, tr),
        10 => average2(average2(l, tl), average2(t, tr)),
        11 => select(l, t, tl),
        12 => clampAddSubtractFull(l, t, tl),
        13 => clampAddSubtractHalf(average2(l, t), tl),
        14, 15 => 0xFF000000, // invalid in spec; libwebp treats as black
    };
}

/// per-byte add / subtract (mod 256)
pub inline fn addPixels(a: u32, b: u32) u32 {
    const ag = (a & 0xFF00FF00) +% (b & 0xFF00FF00);
    const rb = (a & 0x00FF00FF) +% (b & 0x00FF00FF);
    return (ag & 0xFF00FF00) | (rb & 0x00FF00FF);
}

pub inline fn subPixels(a: u32, b: u32) u32 {
    const ag = 0x00FF00FF +% (a & 0xFF00FF00) -% (b & 0xFF00FF00);
    const rb = 0xFF00FF00 +% (a & 0x00FF00FF) -% (b & 0x00FF00FF);
    return (ag & 0xFF00FF00) | (rb & 0x00FF00FF);
}

// ── inverse transforms (decoder) ──

pub fn inversePredictor(t: *const Transform, px: []u32, height: usize) void {
    const width = t.xsize;
    const bw = divRoundUp(width, t.size_bits);
    // first row: top-left = black, rest = L
    px[0] = addPixels(px[0], 0xFF000000);
    for (1..width) |x| px[x] = addPixels(px[x], px[x - 1]);
    for (1..height) |y| {
        const row = y * width;
        px[row] = addPixels(px[row], px[row - width]); // first column: T
        const brow = (y >> t.size_bits) * bw;
        var x: usize = 1;
        while (x < width) {
            const mode: u4 = @truncate(t.data[brow + (x >> t.size_bits)] >> 8);
            const block_end = @min(width, ((x >> t.size_bits) + 1) << t.size_bits);
            while (x < block_end) : (x += 1) {
                px[row + x] = addPixels(px[row + x], predict(mode, px, row + x, width));
            }
        }
    }
}

inline fn colorDelta(t: u8, c: u8) i32 {
    return (@as(i32, @as(i8, @bitCast(t))) * @as(i32, @as(i8, @bitCast(c)))) >> 5;
}

pub fn inverseCrossColor(t: *const Transform, px: []u32, height: usize) void {
    const width = t.xsize;
    const bw = divRoundUp(width, t.size_bits);
    for (0..height) |y| {
        const brow = (y >> t.size_bits) * bw;
        for (0..width) |x| {
            const m = t.data[brow + (x >> t.size_bits)];
            const g2r: u8 = @truncate(m);
            const g2b: u8 = @truncate(m >> 8);
            const r2b: u8 = @truncate(m >> 16);
            const p = px[y * width + x];
            const green: u8 = @truncate(p >> 8);
            var red: i32 = @intCast((p >> 16) & 0xFF);
            var blue: i32 = @intCast(p & 0xFF);
            red = (red + colorDelta(g2r, green)) & 0xFF;
            blue = (blue + colorDelta(g2b, green) + colorDelta(r2b, @intCast(red))) & 0xFF;
            px[y * width + x] = (p & 0xFF00FF00) | (@as(u32, @intCast(red)) << 16) | @as(u32, @intCast(blue));
        }
    }
}

pub fn inverseSubtractGreen(px: []u32) void {
    for (px) |*p| {
        const g = (p.* >> 8) & 0xFF;
        p.* = addPixels(p.*, (g << 16) | g);
    }
}

/// Expands `src` (packed indices, width `divRoundUp(xsize, bits)`) into `dst` (width xsize).
pub fn inverseColorIndexing(t: *const Transform, src: []const u32, dst: []u32, height: usize) void {
    const width = t.xsize;
    const packed_w = divRoundUp(width, t.size_bits);
    const bits_per_px: u5 = @intCast(@as(u32, 8) >> t.size_bits);
    const mask: u32 = (@as(u32, 1) << bits_per_px) - 1;
    const per_byte_mask = (@as(usize, 1) << t.size_bits) - 1;
    for (0..height) |y| {
        for (0..width) |x| {
            const g = (src[y * packed_w + (x >> t.size_bits)] >> 8) & 0xFF;
            const shift: u5 = @intCast((x & per_byte_mask) * bits_per_px);
            const idx = (g >> shift) & mask;
            dst[y * width + x] = if (idx < t.data.len) t.data[idx] else 0;
        }
    }
}

test "pixel add/sub inverse" {
    const a: u32 = 0x12F08001;
    const b: u32 = 0xFF10FF02;
    try std.testing.expectEqual(a, addPixels(subPixels(a, b), b));
    try std.testing.expectEqual(@as(u32, 0x7F7F7F7F), average2(0xFEFEFEFE, 0x00000000));
}
