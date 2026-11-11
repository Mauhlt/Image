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

// ── per-channel helpers: the 4 channels of a pixel as vector lanes ──

const Channels = @Vector(4, i16);

inline fn channels(p: u32) Channels {
    return @as(@Vector(4, u8), @bitCast(p));
}

/// Clamps each channel to 0..255 and packs them back into a pixel.
inline fn pack(c: Channels) u32 {
    // with comptime-known bounds, @min/@max narrow the type to u8
    return @bitCast(@min(@max(c, @as(Channels, @splat(0))), @as(Channels, @splat(255))));
}

inline fn average2(a: u32, b: u32) u32 {
    // per-byte (a + b) / 2 without overflow between lanes
    return (((a ^ b) & 0xFEFEFEFE) >> 1) + (a & b);
}

fn select(l: u32, t: u32, tl: u32) u32 {
    // with p = L + T - TL per channel: sum |p - L| = sum |T - TL|, sum |p - T| = sum |L - TL|
    const pl = @reduce(.Add, @abs(channels(t) - channels(tl)));
    const pt = @reduce(.Add, @abs(channels(l) - channels(tl)));
    return if (pl < pt) l else t;
}

fn clampAddSubtractFull(a: u32, b: u32, c: u32) u32 {
    return pack(channels(a) + channels(b) - channels(c));
}

fn clampAddSubtractHalf(a: u32, b: u32) u32 {
    return pack(channels(a) + @divTrunc(channels(a) - channels(b), @as(Channels, @splat(2))));
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
            switch (mode) {
                inline else => |m| predictRun(m, px, row, x, block_end, width),
            }
            x = block_end;
        }
    }
}

/// Adds predictor `mode` to the pixels [start, end) of the row starting at `row`.
fn predictRun(comptime mode: u4, px: []u32, row: usize, start: usize, end: usize, width: usize) void {
    var x = start;
    if (comptime fromAboveOnly(mode)) {
        // no dependency along the row: a vector of pixels at a time
        const P = @import("../../Colors/misc.zig").N / 4;
        const V = @Vector(4 * P, u8);
        while (x + P <= end) : (x += P) {
            const up = row + x - width;
            const tl: V = @bitCast(px[up - 1 ..][0..P].*);
            const t: V = @bitCast(px[up..][0..P].*);
            const tr: V = @bitCast(px[up + 1 ..][0..P].*); // the last column's is the row's first pixel
            const pred: V = switch (mode) {
                2 => t,
                3 => tr,
                4 => tl,
                8 => average2v(tl, t),
                9 => average2v(t, tr),
                else => @bitCast(@as(@Vector(P, u32), @splat(0xFF000000))),
            };
            const cur: V = @bitCast(px[row + x ..][0..P].*);
            px[row + x ..][0..P].* = @bitCast(cur +% pred);
        }
    }
    while (x < end) : (x += 1) px[row + x] = addPixels(px[row + x], predict(mode, px, row + x, width));
}

/// Predictors that only use the row above (and the constant black).
fn fromAboveOnly(mode: u4) bool {
    return switch (mode) {
        0, 2, 3, 4, 8, 9, 14, 15 => true,
        else => false,
    };
}

/// average2 on each byte of a vector.
inline fn average2v(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return (a & b) + ((a ^ b) >> @splat(1));
}

pub fn inverseCrossColor(t: *const Transform, px: []u32, height: usize) void {
    const width = t.xsize;
    const bw = divRoundUp(width, t.size_bits);
    const block = @as(usize, 1) << t.size_bits;
    for (0..height) |y| {
        const brow = (y >> t.size_bits) * bw;
        var x: usize = 0;
        while (x < width) : (x += block) {
            // one block's multipliers for its run of the row
            const m = t.data[brow + (x >> t.size_bits)];
            const run = px[y * width + x ..][0..@min(block, width - x)];
            var i: usize = 0;
            while (i + 4 <= run.len) : (i += 4) run[i..][0..4].* = crossColor(4, m, run[i..][0..4].*);
            while (i < run.len) : (i += 1) run[i] = crossColor(1, m, .{run[i]})[0];
        }
    }
}

/// Adds (multiplier * channel) >> 5, both as signed bytes: green into red,
/// then green and the new red into blue.
fn crossColor(comptime n: usize, m: u32, p: @Vector(n, u32)) @Vector(n, u32) {
    const I = @Vector(n, i32);
    const g2r: I = @splat(signedByte(m, 0));
    const g2b: I = @splat(signedByte(m, 8));
    const r2b: I = @splat(signedByte(m, 16));
    const byte: I = @splat(0xFF);
    const q: I = @bitCast(p);
    const green = signExtend(n, (q >> @splat(8)) & byte);
    const red = ((q >> @splat(16)) + ((g2r * green) >> @splat(5))) & byte;
    const blue = (q + ((g2b * green) >> @splat(5)) + ((r2b * signExtend(n, red)) >> @splat(5))) & byte;
    return (p & @as(@Vector(n, u32), @splat(0xFF00FF00))) | @as(@Vector(n, u32), @bitCast((red << @splat(16)) | blue));
}

/// 0..255 -> -128..127
fn signExtend(comptime n: usize, b: @Vector(n, i32)) @Vector(n, i32) {
    const half: @Vector(n, i32) = @splat(0x80);
    return (b ^ half) - half;
}

fn signedByte(v: u32, comptime shift: u5) i32 {
    return @as(i8, @bitCast(@as(u8, @truncate(v >> shift))));
}

pub fn inverseSubtractGreen(px: []u32) void {
    var i: usize = 0;
    while (i + 8 <= px.len) : (i += 8) px[i..][0..8].* = addGreen(8, px[i..][0..8].*);
    while (i < px.len) : (i += 1) px[i] = addGreen(1, .{px[i]})[0];
}

/// Adds green to red and blue (mod 256) in each pixel.
fn addGreen(comptime n: usize, p: @Vector(n, u32)) @Vector(n, u32) {
    const V = @Vector(n, u32);
    const g = (p >> @splat(8)) & @as(V, @splat(0xFF));
    const rb = ((p & @as(V, @splat(0x00FF00FF))) + ((g << @splat(16)) | g)) & @as(V, @splat(0x00FF00FF));
    return (p & @as(V, @splat(0xFF00FF00))) | rb;
}

/// Expands `src` (packed indices, width `divRoundUp(xsize, bits)`) into `dst` (width xsize).
pub fn inverseColorIndexing(t: *const Transform, src: []const u32, dst: []u32, height: usize) void {
    switch (t.size_bits) {
        inline 0...3 => |bits| expandIndices(bits, t.data, src, dst, t.xsize, height),
        else => unreachable,
    }
}

/// Each packed pixel's green byte holds 2^size_bits indices, the first in the
/// low bits. Every byte value is expanded once into a table of its colours,
/// so a packed pixel becomes a single copy of up to 8 pixels.
fn expandIndices(comptime size_bits: u5, palette: []const u32, src: []const u32, dst: []u32, width: usize, height: usize) void {
    const per = 1 << size_bits;
    const bits_per_px = 8 >> size_bits;
    var table: [256][per]u32 = undefined;
    for (&table, 0..) |*colors, g| for (colors, 0..) |*c, k| {
        const idx = (g >> @intCast(k * bits_per_px)) & ((1 << bits_per_px) - 1);
        c.* = if (idx < palette.len) palette[idx] else 0; // out of range: transparent black
    };
    const packed_w = divRoundUp(width, size_bits);
    const full = width / per; // packed pixels whose indices all fall inside the row
    for (0..height) |y| {
        const in = src[y * packed_w ..][0..packed_w];
        const out = dst[y * width ..][0..width];
        for (in[0..full], 0..) |p, i| out[i * per ..][0..per].* = table[(p >> 8) & 0xFF];
        const rest = width - full * per;
        if (rest > 0) @memcpy(out[full * per ..], table[(in[full] >> 8) & 0xFF][0..rest]);
    }
}

test "pixel add/sub inverse" {
    const a: u32 = 0x12F08001;
    const b: u32 = 0xFF10FF02;
    try std.testing.expectEqual(a, addPixels(subPixels(a, b), b));
    try std.testing.expectEqual(@as(u32, 0x7F7F7F7F), average2(0xFEFEFEFE, 0x00000000));
}

test "select and clamped predictors match the spec's per-channel formulas" {
    const ref = struct {
        fn ch(p: u32, c: u5) i32 {
            return @intCast((p >> (8 * c)) & 0xFF);
        }
        fn clamp(v: i32) u32 {
            return @intCast(std.math.clamp(v, 0, 255));
        }
    };
    var prng: std.Random.DefaultPrng = .init(3);
    const rand = prng.random();
    for (0..2000) |i| {
        // small spreads make ties and clamping common
        const base = rand.int(u32);
        const mix: u32 = if (i % 2 == 0) 0x0F0F0F0F else 0xFFFFFFFF;
        const l = base ^ (rand.int(u32) & mix);
        const t = base ^ (rand.int(u32) & mix);
        const tl = base ^ (rand.int(u32) & mix);
        var pl: i32 = 0;
        var pt: i32 = 0;
        var full: u32 = 0;
        var half: u32 = 0;
        const avg = average2(l, t);
        for (0..4) |c_| {
            const c: u5 = @intCast(c_);
            const p = ref.ch(l, c) + ref.ch(t, c) - ref.ch(tl, c);
            pl += @intCast(@abs(p - ref.ch(l, c)));
            pt += @intCast(@abs(p - ref.ch(t, c)));
            full |= ref.clamp(p) << (8 * c);
            half |= ref.clamp(ref.ch(avg, c) + @divTrunc(ref.ch(avg, c) - ref.ch(tl, c), 2)) << (8 * c);
        }
        try std.testing.expectEqual(if (pl < pt) l else t, select(l, t, tl));
        try std.testing.expectEqual(full, clampAddSubtractFull(l, t, tl));
        try std.testing.expectEqual(half, clampAddSubtractHalf(avg, tl));
    }
}

test "inverse predictor undoes each mode's per-pixel prediction" {
    const w = 37; // not a multiple of the 4-pixel vectors or the blocks
    const h = 9;
    const bits: u5 = 2;
    var prng: std.Random.DefaultPrng = .init(1);
    const rand = prng.random();
    var orig: [w * h]u32 = undefined;
    for (&orig) |*p| p.* = rand.int(u32);
    var modes: [divRoundUp(w, bits) * divRoundUp(h, bits)]u32 = undefined;
    for (&modes, 0..) |*m, i| m.* = @as(u32, @intCast(i % 16)) << 8; // every mode, several times
    // residuals as an encoder makes them, with the per-pixel `predict`
    var px: [w * h]u32 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const pos = y * w + x;
        const pred = if (pos == 0) 0xFF000000 else if (y == 0) orig[pos - 1] else if (x == 0) orig[pos - w] else blk: {
            const mode: u4 = @truncate(modes[(y >> bits) * divRoundUp(w, bits) + (x >> bits)] >> 8);
            break :blk predict(mode, &orig, pos, w);
        };
        px[pos] = subPixels(orig[pos], pred);
    };
    const t: Transform = .{ .type = .predictor, .xsize = w, .size_bits = bits, .data = &modes };
    inversePredictor(&t, &px, h);
    try std.testing.expectEqualSlices(u32, &orig, &px);
}

test "inverse cross colour matches the spec's per-pixel formula" {
    const w = 23;
    const h = 5;
    const bits: u5 = 3;
    var prng: std.Random.DefaultPrng = .init(2);
    const rand = prng.random();
    var mult: [divRoundUp(w, bits) * divRoundUp(h, bits)]u32 = undefined;
    for (&mult) |*m| m.* = rand.int(u32);
    var px: [w * h]u32 = undefined;
    for (&px) |*p| p.* = rand.int(u32);
    var want = px;
    const delta = struct {
        fn f(t: u32, c: u32) u32 {
            const ts: i32 = @as(i8, @bitCast(@as(u8, @truncate(t))));
            const cs: i32 = @as(i8, @bitCast(@as(u8, @truncate(c))));
            return @bitCast((ts * cs) >> 5);
        }
    }.f;
    for (0..h) |y| for (0..w) |x| {
        const m = mult[(y >> bits) * divRoundUp(w, bits) + (x >> bits)];
        const p = want[y * w + x];
        const red = ((p >> 16) +% delta(m, p >> 8)) & 0xFF;
        const blue = (p +% delta(m >> 8, p >> 8) +% delta(m >> 16, red)) & 0xFF;
        want[y * w + x] = (p & 0xFF00FF00) | (red << 16) | blue;
    };
    const t: Transform = .{ .type = .cross_color, .xsize = w, .size_bits = bits, .data = &mult };
    inverseCrossColor(&t, &px, h);
    try std.testing.expectEqualSlices(u32, &want, &px);
}

test "inverse subtract green and colour indexing, per pixel" {
    var px: [19]u32 = undefined;
    for (&px, 0..) |*p, i| p.* = @as(u32, @intCast(i)) *% 0x9E3779B9;
    var want = px;
    for (&want) |*p| p.* = addPixels(p.*, ((p.* >> 8) & 0xFF) * 0x00010001);
    inverseSubtractGreen(&px);
    try std.testing.expectEqualSlices(u32, &want, &px);

    // 4 colours, 4 two-bit indices per packed pixel; index 3 is past the palette
    var palette = [_]u32{ 0x11111111, 0x22222222, 0x33333333 };
    const width = 7;
    const src = [_]u32{ 0b11_10_01_00 << 8, 0b00_00_10_01 << 8 };
    var dst: [width]u32 = undefined;
    const t: Transform = .{ .type = .color_indexing, .xsize = width, .size_bits = 2, .data = &palette };
    inverseColorIndexing(&t, &src, &dst, 1);
    try std.testing.expectEqualSlices(u32, &.{ palette[0], palette[1], palette[2], 0, palette[1], palette[2], palette[0] }, &dst);
}

test "vector predictor runs at vector-edge widths match the per-pixel predictor" {
    const P = @import("../../Colors/misc.zig").N / 4; // as predictRun
    var prng: std.Random.DefaultPrng = .init(9);
    const rand = prng.random();
    var buf: [3 * (4 * P + 8)]u32 = undefined;
    for ([_]usize{ 2, 3, 7, 15, 17, 33, P, P + 1, P + 2, 2 * P + 3, 4 * P + 8 }) |width| {
        inline for (.{ 0, 2, 3, 4, 8, 9, 14, 15 }) |mode| {
            const px = buf[0 .. 2 * width];
            rand.bytes(std.mem.sliceAsBytes(px));
            var ref: [3 * (4 * P + 8)]u32 = undefined;
            @memcpy(ref[0..px.len], px);
            const row = width;
            // the decoder starts each row at x = 1 (column 0 predicts from T)
            predictRun(mode, px, row, 1, width, width);
            for (1..width) |x| ref[row + x] = addPixels(ref[row + x], predict(mode, ref[0..px.len], row + x, width));
            try std.testing.expectEqualSlices(u32, ref[0..px.len], px);
        }
    }
}
