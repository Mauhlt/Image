//! VP8L (lossless WebP) encoder.
//!   <= 256 colors : color-indexing transform (pixels bit-packed 1/2/4/8 per byte)
//!   otherwise     : subtract-green + per-block best predictor, color cache
//! then greedy LZ77 (hash chain) + length-limited Huffman.
const std = @import("std");
const BitWriter = @import("bitwriter.zig");
const huffman = @import("huffman.zig");
const tf = @import("transform.zig");
const dec = @import("decode.zig");
const VP8L_SIG = @import("header.zig").VP8L_SIG;

const NUM_LENGTH_CODES = 24;
const NUM_DISTANCE_CODES = 40;
const MAX_LENGTH = 4096;
const MIN_MATCH = 3;
const PREDICTOR_BITS: u5 = 4;
const CACHE_BITS: u4 = 10;
const HASH_BITS = 16;
const MAX_CHAIN = 16;
/// largest distance whose (distance + 120) still fits in 40 prefix codes
const MAX_DISTANCE = (1 << 20) - 120;

/// Returns the VP8L bitstream (signature + header + data); caller frees.
pub fn encodeArgb(gpa: std.mem.Allocator, argb: []const u32, width: usize, height: usize, has_alpha: bool) ![]u8 {
    var bw: BitWriter = .{ .gpa = gpa };
    errdefer bw.deinit();
    try bw.writeBits(VP8L_SIG, 8);
    try bw.writeBits(@intCast(width - 1), 14);
    try bw.writeBits(@intCast(height - 1), 14);
    try bw.writeBits(@intFromBool(has_alpha), 1);
    try bw.writeBits(0, 3); // version

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const scratch = arena.allocator();

    const px = try scratch.dupe(u32, argb);
    var xsize = width;
    var cache_bits: u4 = CACHE_BITS;

    if (try palette(scratch, px)) |pal| {
        // ── color indexing ──
        try bw.writeBits(1, 1);
        try bw.writeBits(@intFromEnum(tf.Type.color_indexing), 2);
        try bw.writeBits(@intCast(pal.len - 1), 8);
        const delta = try scratch.alloc(u32, pal.len);
        for (delta, 0..) |*d, i| d.* = if (i == 0) pal[0] else tf.subPixels(pal[i], pal[i - 1]);
        try writeImage(gpa, scratch, &bw, delta, pal.len, false, 0);

        const size_bits: u5 = if (pal.len <= 2) 3 else if (pal.len <= 4) 2 else if (pal.len <= 16) 1 else 0;
        const bits_per_px: u5 = @intCast(@as(u32, 8) >> size_bits);
        var lookup: std.AutoHashMapUnmanaged(u32, u8) = .empty;
        for (pal, 0..) |c, i| try lookup.put(scratch, c, @intCast(i));
        xsize = tf.divRoundUp(width, size_bits);
        const packed_px = try scratch.alloc(u32, xsize * height);
        @memset(packed_px, 0);
        for (0..height) |y| for (0..width) |x| {
            const idx: u32 = lookup.get(px[y * width + x]).?;
            const shift: u5 = @intCast((x & ((@as(usize, 1) << size_bits) - 1)) * bits_per_px);
            packed_px[y * xsize + (x >> size_bits)] |= idx << (shift + 8);
        };
        for (packed_px) |*p| p.* |= 0xFF000000;
        cache_bits = 0;
        try bw.writeBits(0, 1); // no more transforms
        try writeImage(gpa, scratch, &bw, packed_px, xsize, true, cache_bits);
    } else {
        // ── subtract green ──
        try bw.writeBits(1, 1);
        try bw.writeBits(@intFromEnum(tf.Type.subtract_green), 2);
        for (px) |*p| {
            const g = (p.* >> 8) & 0xFF;
            p.* = tf.subPixels(p.*, (g << 16) | g);
        }
        // ── predictor ──
        try bw.writeBits(1, 1);
        try bw.writeBits(@intFromEnum(tf.Type.predictor), 2);
        try bw.writeBits(PREDICTOR_BITS - 2, 3);
        const modes = try choosePredictors(scratch, px, width, height);
        try writeImage(gpa, scratch, &bw, modes, tf.divRoundUp(width, PREDICTOR_BITS), false, 0);
        const residual = try applyPredictors(scratch, px, width, height, modes);
        try bw.writeBits(0, 1); // no more transforms
        try writeImage(gpa, scratch, &bw, residual, width, true, cache_bits);
    }

    _ = try bw.finish();
    return bw.out.toOwnedSlice(gpa);
}

/// Unique colors if there are at most 256, else null.
fn palette(scratch: std.mem.Allocator, px: []const u32) !?[]u32 {
    var set: std.AutoArrayHashMapUnmanaged(u32, void) = .empty;
    var last: u32 = px[0] +% 1;
    for (px) |p| {
        if (p == last) continue;
        last = p;
        try set.put(scratch, p, {});
        if (set.count() > 256) return null;
    }
    const keys = set.keys();
    std.mem.sort(u32, keys, {}, std.sort.asc(u32)); // nearby colors -> small deltas
    return keys;
}

fn choosePredictors(scratch: std.mem.Allocator, px: []const u32, width: usize, height: usize) ![]u32 {
    const bw = tf.divRoundUp(width, PREDICTOR_BITS);
    const bh = tf.divRoundUp(height, PREDICTOR_BITS);
    const modes = try scratch.alloc(u32, bw * bh);
    for (0..bh) |by| for (0..bw) |bx| {
        var best_mode: u32 = 1;
        var best_cost: u64 = std.math.maxInt(u64);
        for (0..14) |m| {
            var cost: u64 = 0;
            const y0 = by << PREDICTOR_BITS;
            const x0 = bx << PREDICTOR_BITS;
            for (@max(y0, 1)..@min(y0 + (1 << PREDICTOR_BITS), height)) |y| {
                for (@max(x0, 1)..@min(x0 + (1 << PREDICTOR_BITS), width)) |x| {
                    const pos = y * width + x;
                    const r = tf.subPixels(px[pos], tf.predict(@intCast(m), px, pos, width));
                    inline for (.{ 0, 8, 16, 24 }) |s| cost += @abs(@as(i8, @bitCast(@as(u8, @truncate(r >> s)))));
                }
            }
            if (cost < best_cost) {
                best_cost = cost;
                best_mode = @intCast(m);
            }
        }
        modes[by * bw + bx] = 0xFF000000 | (best_mode << 8);
    };
    return modes;
}

fn applyPredictors(scratch: std.mem.Allocator, px: []const u32, width: usize, height: usize, modes: []const u32) ![]u32 {
    const res = try scratch.alloc(u32, px.len);
    const bw = tf.divRoundUp(width, PREDICTOR_BITS);
    res[0] = tf.subPixels(px[0], 0xFF000000);
    for (1..width) |x| res[x] = tf.subPixels(px[x], px[x - 1]);
    for (1..height) |y| {
        res[y * width] = tf.subPixels(px[y * width], px[(y - 1) * width]);
        for (1..width) |x| {
            const pos = y * width + x;
            const mode: u4 = @truncate(modes[(y >> PREDICTOR_BITS) * bw + (x >> PREDICTOR_BITS)] >> 8);
            res[pos] = tf.subPixels(px[pos], tf.predict(mode, px, pos, width));
        }
    }
    return res;
}

const Token = union(enum) {
    literal: u32,
    cache: u16,
    copy: struct { len: u16, dist_code: u32 },
};

/// value >= 1 -> (prefix symbol, extra bit count, extra bits)
fn prefixEncode(value: usize) struct { sym: u16, n_extra: u6, extra: u32 } {
    const n = value - 1;
    if (n < 4) return .{ .sym = @intCast(n), .n_extra = 0, .extra = 0 };
    const h: u6 = @intCast(std.math.log2_int(usize, n));
    const second: u16 = @intCast((n >> @intCast(h - 1)) & 1);
    const n_extra: u6 = h - 1;
    return .{
        .sym = 2 * @as(u16, h) + second,
        .n_extra = n_extra,
        .extra = @intCast(n & ((@as(usize, 1) << n_extra) - 1)),
    };
}

fn distanceCode(dist: usize, xsize: usize) u32 {
    if (dist == xsize) return 1;
    if (dist == 1) return 2;
    return @intCast(dist + 120);
}

/// Entropy-coded image: optional color cache, (main only) "no meta codes", 5 trees, symbols.
fn writeImage(
    gpa: std.mem.Allocator,
    scratch: std.mem.Allocator,
    bw: *BitWriter,
    px: []const u32,
    xsize: usize,
    is_main: bool,
    cache_bits: u4,
) !void {
    const tokens = try tokenize(scratch, px, xsize, cache_bits, is_main);

    if (cache_bits > 0) {
        try bw.writeBits(1, 1);
        try bw.writeBits(cache_bits, 4);
    } else try bw.writeBits(0, 1);
    if (is_main) try bw.writeBits(0, 1); // no meta prefix codes

    const cache_size: usize = if (cache_bits > 0) @as(usize, 1) << cache_bits else 0;
    const green = try scratch.alloc(u32, 256 + NUM_LENGTH_CODES + cache_size);
    @memset(green, 0);
    var red: [256]u32 = @splat(0);
    var blue: [256]u32 = @splat(0);
    var alpha: [256]u32 = @splat(0);
    var dist: [NUM_DISTANCE_CODES]u32 = @splat(0);
    for (tokens) |t| switch (t) {
        .literal => |p| {
            green[(p >> 8) & 0xFF] += 1;
            red[(p >> 16) & 0xFF] += 1;
            blue[p & 0xFF] += 1;
            alpha[p >> 24] += 1;
        },
        .cache => |i| green[256 + NUM_LENGTH_CODES + i] += 1,
        .copy => |c| {
            green[256 + prefixEncode(c.len).sym] += 1;
            dist[prefixEncode(c.dist_code).sym] += 1;
        },
    };

    const codes = [5]huffman.Code{
        try huffman.writeTree(gpa, bw, green),
        try huffman.writeTree(gpa, bw, &red),
        try huffman.writeTree(gpa, bw, &blue),
        try huffman.writeTree(gpa, bw, &alpha),
        try huffman.writeTree(gpa, bw, &dist),
    };
    defer for (codes) |c| c.deinit(gpa);

    for (tokens) |t| switch (t) {
        .literal => |p| {
            try codes[0].write(bw, (p >> 8) & 0xFF);
            try codes[1].write(bw, (p >> 16) & 0xFF);
            try codes[2].write(bw, p & 0xFF);
            try codes[3].write(bw, p >> 24);
        },
        .cache => |i| try codes[0].write(bw, 256 + NUM_LENGTH_CODES + @as(usize, i)),
        .copy => |c| {
            const l = prefixEncode(c.len);
            try codes[0].write(bw, 256 + @as(usize, l.sym));
            try bw.writeBits(l.extra, l.n_extra);
            const d = prefixEncode(c.dist_code);
            try codes[4].write(bw, d.sym);
            try bw.writeBits(d.extra, d.n_extra);
        },
    };
}

fn tokenize(scratch: std.mem.Allocator, px: []const u32, xsize: usize, cache_bits: u4, use_lz77: bool) ![]Token {
    var tokens: std.ArrayList(Token) = .empty;
    try tokens.ensureTotalCapacity(scratch, px.len / 4 + 16);
    const cache_size: usize = if (cache_bits > 0) @as(usize, 1) << cache_bits else 0;
    const cache = try scratch.alloc(u32, cache_size);
    @memset(cache, 0);

    // hash chains over 3-pixel windows
    const head = try scratch.alloc(i32, if (use_lz77) 1 << HASH_BITS else 0);
    @memset(head, -1);
    const prev = try scratch.alloc(i32, if (use_lz77) px.len else 0);

    const Hash = struct {
        fn of(p: []const u32, i: usize) usize {
            const h = (p[i] *% 0x9E3779B1) ^ (p[i + 1] *% 0x85EBCA77) ^ (p[i + 2] *% 0xC2B2AE3D);
            return h >> (32 - HASH_BITS);
        }
    };
    const insert = struct {
        fn f(hd: []i32, pv: []i32, p: []const u32, i: usize) void {
            if (i + 2 >= p.len) return;
            const h = Hash.of(p, i);
            pv[i] = hd[h];
            hd[h] = @intCast(i);
        }
    }.f;

    var pos: usize = 0;
    while (pos < px.len) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (use_lz77 and pos + MIN_MATCH <= px.len) {
            const max_len = @min(MAX_LENGTH, px.len - pos);
            // the two cheapest distances first: left and above
            for ([_]usize{ 1, xsize }) |d| {
                if (d == 0 or d > pos) continue;
                var l: usize = 0;
                while (l < max_len and px[pos + l] == px[pos + l - d]) l += 1;
                if (l > best_len) {
                    best_len = l;
                    best_dist = d;
                }
            }
            if (best_len < max_len) {
                var cand = head[Hash.of(px, pos)];
                var chain: usize = 0;
                while (cand >= 0 and chain < MAX_CHAIN) : (chain += 1) {
                    const c: usize = @intCast(cand);
                    const d = pos - c;
                    if (d > MAX_DISTANCE) break;
                    var l: usize = 0;
                    while (l < max_len and px[pos + l] == px[c + l]) l += 1;
                    if (l > best_len + 1) { // prefer the cheap plane codes on ties
                        best_len = l;
                        best_dist = d;
                    }
                    cand = prev[c];
                }
            }
        }

        if (best_len >= MIN_MATCH) {
            try tokens.append(scratch, .{ .copy = .{ .len = @intCast(best_len), .dist_code = distanceCode(best_dist, xsize) } });
            for (pos..pos + best_len) |i| {
                if (use_lz77) insert(head, prev, px, i);
                if (cache_size > 0) cache[dec.cacheIndex(px[i], cache_bits)] = px[i];
            }
            pos += best_len;
            continue;
        }

        const p = px[pos];
        if (cache_size > 0) {
            const idx = dec.cacheIndex(p, cache_bits);
            if (cache[idx] == p) {
                try tokens.append(scratch, .{ .cache = @intCast(idx) });
            } else {
                try tokens.append(scratch, .{ .literal = p });
                cache[idx] = p;
            }
        } else try tokens.append(scratch, .{ .literal = p });
        if (use_lz77) insert(head, prev, px, pos);
        pos += 1;
    }
    return tokens.items;
}

test "prefix encode matches decoder" {
    const BitReader = @import("bitreader.zig");
    const gpa = std.testing.allocator;
    for ([_]usize{ 1, 2, 4, 5, 6, 7, 8, 9, 100, 4096, 70000, MAX_DISTANCE + 120 }) |v| {
        const e = prefixEncode(v);
        try std.testing.expect(e.sym < 40);
        var bw: BitWriter = .{ .gpa = gpa };
        defer bw.deinit();
        try bw.writeBits(e.extra, e.n_extra);
        var br: BitReader = .{ .data = try bw.finish() };
        // mirror decode.prefixValue
        const got = if (e.sym < 4) e.sym + 1 else blk: {
            const extra: u6 = @intCast((e.sym - 2) >> 1);
            const offset = (@as(usize, 2) + (e.sym & 1)) << extra;
            break :blk offset + br.readBits(extra) + 1;
        };
        try std.testing.expectEqual(v, got);
    }
}
