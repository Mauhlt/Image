//! VP8L (lossless WebP) bitstream decoder. RFC 9649.
const std = @import("std");
const Error = @import("../error.zig").Error;
const BitReader = @import("bitreader.zig");
const huffman = @import("huffman.zig");
const tf = @import("transform.zig");
const Transform = tf.Transform;

const NUM_LENGTH_CODES = 24;
const NUM_DISTANCE_CODES = 40;
const COLOR_CACHE_MULT: u32 = 0x1e35a7bd;

/// (dx, dy) for distance codes 1..120 (spec 5.2.2)
const DISTANCE_MAP = [120][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },  .{ 1, 2 },
    .{ -1, 2 }, .{ 2, 1 },  .{ -2, 1 }, .{ 2, 2 },  .{ -2, 2 }, .{ 0, 3 },  .{ 3, 0 },
    .{ 1, 3 },  .{ -1, 3 }, .{ 3, 1 },  .{ -3, 1 }, .{ 2, 3 },  .{ -2, 3 }, .{ 3, 2 },
    .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },  .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 },
    .{ 3, 3 },  .{ -3, 3 }, .{ 2, 4 },  .{ -2, 4 }, .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },
    .{ 3, 4 },  .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },  .{ 1, 5 },  .{ -1, 5 },
    .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 }, .{ 4, 4 },
    .{ -4, 4 }, .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 }, .{ 0, 6 },  .{ 6, 0 },
    .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 }, .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },
    .{ -6, 2 }, .{ 4, 5 },  .{ -4, 5 }, .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 },
    .{ 6, 3 },  .{ -6, 3 }, .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },
    .{ -5, 5 }, .{ 7, 1 },  .{ -7, 1 }, .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 },
    .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 }, .{ 3, 7 },  .{ -3, 7 }, .{ 7, 3 },
    .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 }, .{ 8, 0 },  .{ 4, 7 },
    .{ -4, 7 }, .{ 7, 4 },  .{ -7, 4 }, .{ 8, 1 },  .{ 8, 2 },  .{ 6, 6 },  .{ -6, 6 },
    .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 }, .{ 7, 5 },  .{ -7, 5 }, .{ 8, 4 },  .{ 6, 7 },
    .{ -6, 7 }, .{ 7, 6 },  .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },
    .{ 8, 7 },
};

pub fn distanceFromCode(code: usize, xsize: usize) usize {
    if (code > 120) return code - 120;
    const d = DISTANCE_MAP[code - 1];
    const dist = @as(isize, d[0]) + @as(isize, d[1]) * @as(isize, @intCast(xsize));
    return if (dist < 1) 1 else @intCast(dist);
}

pub inline fn cacheIndex(argb: u32, bits: u4) usize {
    return (argb *% COLOR_CACHE_MULT) >> @intCast(32 - @as(u6, bits));
}

/// prefix-coded length / distance value
fn prefixValue(br: *BitReader, prefix: u16) usize {
    if (prefix < 4) return prefix + 1;
    const extra: u6 = @intCast((prefix - 2) >> 1);
    const offset = (@as(usize, 2) + (prefix & 1)) << extra;
    return offset + br.readBits(extra) + 1;
}

const Group = struct { trees: [5]huffman.Tree };

/// Decodes a full VP8L bitstream (including its 5-byte header) into ARGB pixels.
pub fn decodeArgb(scratch: std.mem.Allocator, bitstream: []const u8, width: usize, height: usize, out: []u32) !void {
    return decodeImageStream(scratch, bitstream[5..], width, height, out);
}

/// Decodes a VP8L "image-stream" whose size is known from elsewhere (no
/// header): the body of a VP8L chunk, or a lossless-compressed ALPH chunk.
pub fn decodeImageStream(scratch: std.mem.Allocator, stream: []const u8, width: usize, height: usize, out: []u32) !void {
    std.debug.assert(out.len == width * height);
    var br: BitReader = .{ .data = stream };

    // transforms, in stream order
    var transforms: [4]Transform = undefined;
    var n_transforms: usize = 0;
    var seen: [4]bool = @splat(false);
    var xsize = width;
    while (br.readBit()) {
        const t_type: tf.Type = @enumFromInt(br.readBits(2));
        if (seen[@intFromEnum(t_type)]) return Error.InvalidTransform;
        seen[@intFromEnum(t_type)] = true;
        var t: Transform = .{ .type = t_type, .xsize = xsize };
        switch (t_type) {
            .predictor, .cross_color => {
                t.size_bits = @intCast(br.readBits(3) + 2);
                const bw = tf.divRoundUp(xsize, t.size_bits);
                const bh = tf.divRoundUp(height, t.size_bits);
                t.data = try scratch.alloc(u32, bw * bh);
                try decodeImage(scratch, &br, bw, bh, false, t.data);
            },
            .subtract_green => {},
            .color_indexing => {
                const n_colors = br.readBits(8) + 1;
                t.data = try scratch.alloc(u32, n_colors);
                try decodeImage(scratch, &br, n_colors, 1, false, t.data);
                for (1..n_colors) |i| t.data[i] = tf.addPixels(t.data[i], t.data[i - 1]);
                t.size_bits = if (n_colors <= 2) 3 else if (n_colors <= 4) 2 else if (n_colors <= 16) 1 else 0;
                xsize = tf.divRoundUp(xsize, t.size_bits);
            },
        }
        transforms[n_transforms] = t;
        n_transforms += 1;
    }

    // main image (possibly packed narrower by color indexing)
    const packed_px = if (xsize == width) out else try scratch.alloc(u32, xsize * height);
    try decodeImage(scratch, &br, xsize, height, true, packed_px);

    // inverse transforms in reverse order
    var cur = packed_px;
    var i = n_transforms;
    while (i > 0) {
        i -= 1;
        const t = &transforms[i];
        switch (t.type) {
            .predictor => tf.inversePredictor(t, cur, height),
            .cross_color => tf.inverseCrossColor(t, cur, height),
            .subtract_green => tf.inverseSubtractGreen(cur),
            .color_indexing => {
                const dst = if (t.xsize == width) out else try scratch.alloc(u32, t.xsize * height);
                tf.inverseColorIndexing(t, cur, dst, height);
                cur = dst;
            },
        }
    }
    if (cur.ptr != out.ptr) @memcpy(out, cur);
}

/// Entropy-coded image. `is_main` enables meta prefix codes (the "level 0" image).
fn decodeImage(
    scratch: std.mem.Allocator,
    br: *BitReader,
    xsize: usize,
    ysize: usize,
    is_main: bool,
    out: []u32,
) !void {
    // color cache
    var cache_bits: u4 = 0;
    if (br.readBit()) {
        const b = br.readBits(4);
        if (b < 1 or b > 11) return Error.InvalidColorCacheIndex;
        cache_bits = @intCast(b);
    }
    const cache_size: usize = if (cache_bits > 0) @as(usize, 1) << cache_bits else 0;
    const cache = try scratch.alloc(u32, cache_size);
    defer scratch.free(cache);
    @memset(cache, 0);

    // meta prefix codes
    var prefix_bits: u5 = 0;
    var entropy_img: []u32 = &.{};
    var n_groups: usize = 1;
    if (is_main and br.readBit()) {
        prefix_bits = @intCast(br.readBits(3) + 2);
        const ew = tf.divRoundUp(xsize, prefix_bits);
        const eh = tf.divRoundUp(ysize, prefix_bits);
        entropy_img = try scratch.alloc(u32, ew * eh);
        try decodeImage(scratch, br, ew, eh, false, entropy_img);
        for (entropy_img) |*e| {
            e.* = (e.* >> 8) & 0xFFFF;
            n_groups = @max(n_groups, e.* + 1);
        }
    }
    defer scratch.free(entropy_img);
    const ew = if (prefix_bits > 0) tf.divRoundUp(xsize, prefix_bits) else 1;

    const groups = try scratch.alloc(Group, n_groups);
    defer scratch.free(groups);
    const alphabet = [5]usize{ 256 + NUM_LENGTH_CODES + cache_size, 256, 256, 256, NUM_DISTANCE_CODES };
    for (groups) |*g| {
        for (&g.trees, alphabet) |*t, n| t.* = try huffman.readTree(scratch, br, n);
    }

    const total = xsize * ysize;
    var pos: usize = 0;
    var last_cached: usize = 0; // pixels [last_cached, pos) still need inserting into the cache
    var group = &groups[0];
    while (pos < total) {
        const x = pos % xsize;
        if (prefix_bits > 0 and (x & ((@as(usize, 1) << prefix_bits) - 1)) == 0) {
            const y = pos / xsize;
            group = &groups[entropy_img[(y >> prefix_bits) * ew + (x >> prefix_bits)]];
        }
        const s = try group.trees[0].decode(br);
        if (s < 256) {
            const r = try group.trees[1].decode(br);
            const b = try group.trees[2].decode(br);
            const a = try group.trees[3].decode(br);
            out[pos] = (@as(u32, a) << 24) | (@as(u32, r) << 16) | (@as(u32, s) << 8) | b;
            pos += 1;
        } else if (s < 256 + NUM_LENGTH_CODES) {
            const length = prefixValue(br, s - 256);
            const dist_sym = try group.trees[4].decode(br);
            const dist = distanceFromCode(prefixValue(br, dist_sym), xsize);
            if (dist > pos or pos + length > total) return Error.InvalidBackReference;
            for (0..length) |k| out[pos + k] = out[pos + k - dist]; // may overlap
            pos += length;
            // the group can change inside a copy; re-pick for the next symbol
            if (prefix_bits > 0 and pos < total) {
                const nx = pos % xsize;
                const ny = pos / xsize;
                group = &groups[entropy_img[(ny >> prefix_bits) * ew + (nx >> prefix_bits)]];
            }
        } else {
            const idx = s - 256 - NUM_LENGTH_CODES;
            if (idx >= cache_size) return Error.InvalidColorCacheIndex;
            // cache must be up to date before a lookup
            while (last_cached < pos) : (last_cached += 1) cache[cacheIndex(out[last_cached], cache_bits)] = out[last_cached];
            out[pos] = cache[idx];
            pos += 1;
        }
        if (cache_bits > 0) {
            while (last_cached < pos) : (last_cached += 1) cache[cacheIndex(out[last_cached], cache_bits)] = out[last_cached];
        }
    }
    try br.check();
}

test "distance map" {
    try std.testing.expectEqual(@as(usize, 100), distanceFromCode(1, 100)); // (0,1) = row above
    try std.testing.expectEqual(@as(usize, 1), distanceFromCode(2, 100)); // (1,0) = left
    try std.testing.expectEqual(@as(usize, 5), distanceFromCode(125, 100));
}
