//! Tests for inflate.zig: differential against std.compress.flate, hand-built
//! streams (fixed / dynamic with long codes, every length and distance code,
//! overlapping copies), external gzip output, PNG IDAT streams, malformed input and
//! a bit-flip fuzz loop.
const std = @import("std");
const inflate = @import("inflate.zig");
const flate = std.compress.flate;
const testing = std.testing;
const gpa = testing.allocator;

// ───────────────────────────── helpers ─────────────────────────────

fn stdContainer(c: inflate.Container) flate.Container {
    return switch (c) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
    };
}

const Level = union(enum) { opts: flate.Compress.Options, stored, huffman };

fn stdCompress(data: []const u8, c: inflate.Container, level: Level) ![]u8 {
    var aw: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
    errdefer aw.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    switch (level) {
        .opts => |o| {
            var comp: flate.Compress = try .init(&aw.writer, window, stdContainer(c), o);
            try comp.writer.writeAll(data);
            try comp.finish();
        },
        .stored => {
            var comp: flate.Compress.Raw = try .init(&aw.writer, window, stdContainer(c));
            try comp.writer.writeAll(data);
            try comp.finish();
        },
        .huffman => {
            var comp: flate.Compress.Huffman = try .init(&aw.writer, window, stdContainer(c));
            try comp.writer.writeAll(data);
            try comp.finish();
        },
    }
    return aw.toOwnedSlice();
}

/// std's decode of `in`, or null if std rejects it.
fn stdDecompress(in: []const u8, c: inflate.Container) !?[]u8 {
    var r: std.Io.Reader = .fixed(in);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var dec: flate.Decompress = .init(&r, stdContainer(c), window);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    _ = dec.reader.streamRemaining(&aw.writer) catch |e| switch (e) {
        error.ReadFailed => {
            aw.deinit();
            return null;
        },
        else => |x| return x,
    };
    return try aw.toOwnedSlice();
}

/// Decodes `in` into an exactly sized buffer and checks it equals `want`, and that
/// the whole input was consumed. Also checks the split (head ++ out) form.
fn expectDecodes(c: inflate.Container, in: []const u8, want: []const u8) !void {
    const out = try gpa.alloc(u8, want.len);
    defer gpa.free(out);
    const r = try inflate.decompress(c, in, out, .{});
    try testing.expectEqual(want.len, r.out_len);
    try testing.expectEqual(in.len, r.in_len);
    try testing.expectEqualSlices(u8, want, out);
    if (want.len > 0) {
        const cuts = [_]usize{ 1, 352, want.len / 2, want.len - 1, want.len };
        for (cuts) |cut| {
            if (cut > want.len) continue;
            @memset(out, 0);
            const r2 = try inflate.decompressSplit(c, in, out[0..cut], out[cut..], .{});
            try testing.expectEqual(want.len, r2.out_len);
            try testing.expectEqualSlices(u8, want, out);
        }
    }
    // one byte short must not fit
    if (want.len > 0) {
        try testing.expectError(error.OutputTooSmall, inflate.decompress(c, in, out[0 .. want.len - 1], .{}));
    }
}

const Gen = enum { zeros, random, text, runs, words16, mixed };

fn genData(kind: Gen, n: usize, seed: u64) ![]u8 {
    const d = try gpa.alloc(u8, n);
    var rng: std.Random.DefaultPrng = .init(seed);
    const r = rng.random();
    switch (kind) {
        .zeros => @memset(d, 0),
        .random => r.bytes(d),
        .text => {
            const words = [_][]const u8{ "the ", "quick ", "brown ", "fox ", "jumps ", "over ", "lazy ", "dog ", "\n", "inflate ", "zig ", "voxel " };
            var i: usize = 0;
            while (i < n) {
                const w = words[r.uintLessThan(usize, words.len)];
                const k = @min(w.len, n - i);
                @memcpy(d[i..][0..k], w[0..k]);
                i += k;
            }
        },
        .runs => {
            var i: usize = 0;
            while (i < n) {
                const k = @min(n - i, 1 + r.uintLessThan(usize, 600));
                @memset(d[i..][0..k], r.int(u8));
                i += k;
            }
        },
        .words16 => { // smooth 16-bit samples, like MRI voxels
            var v: i32 = 1000;
            var i: usize = 0;
            while (i + 1 < n) : (i += 2) {
                v += r.intRangeAtMost(i32, -3, 3);
                std.mem.writeInt(u16, d[i..][0..2], @truncate(@as(u32, @bitCast(v))), .little);
            }
            if (n % 2 == 1) d[n - 1] = 7;
        },
        .mixed => {
            r.bytes(d);
            var i: usize = 0;
            while (i < n) : (i += 1 + r.uintLessThan(usize, 3000)) {
                const k = @min(n - i, r.uintLessThan(usize, 2000));
                if (r.boolean()) @memset(d[i..][0..k], 0) else if (i >= 40000) @memcpy(d[i..][0..k], d[i - 32768 ..][0..k]);
            }
        },
    }
    return d;
}

// ───────────────────────────── hand-built streams ─────────────────────────────

const BitWriter = struct {
    bytes: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    n: u6 = 0,

    fn deinit(w: *BitWriter) void {
        w.bytes.deinit(gpa);
    }
    /// LSB-first value bits.
    fn bits(w: *BitWriter, v: u32, n: u6) !void {
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            w.acc |= @as(u64, (v >> @intCast(i)) & 1) << w.n;
            w.n += 1;
            if (w.n == 8) {
                try w.bytes.append(gpa, @truncate(w.acc));
                w.acc = 0;
                w.n = 0;
            }
        }
    }
    /// Huffman code, MSB first.
    fn code(w: *BitWriter, c: u32, len: u6) !void {
        var i: u6 = len;
        while (i > 0) {
            i -= 1;
            try w.bits((c >> @intCast(i)) & 1, 1);
        }
    }
    fn flush(w: *BitWriter) !void {
        if (w.n > 0) try w.bits(0, 8 - w.n);
    }
};

const Token = union(enum) { lit: u8, match: struct { len: u16, dist: u16 } };

fn apply(tokens: []const Token, out: *std.ArrayList(u8)) !void {
    for (tokens) |t| switch (t) {
        .lit => |b| try out.append(gpa, b),
        .match => |m| for (0..m.len) |_| try out.append(gpa, out.items[out.items.len - m.dist]),
    };
}

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u6{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u6{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

fn lenCode(len: u16) usize {
    if (len == 258) return 28;
    var i: usize = 27;
    while (len_base[i] > len) i -= 1;
    return i;
}
fn distCode(dist: u16) usize {
    var i: usize = 29;
    while (dist_base[i] > dist) i -= 1;
    return i;
}

/// Canonical codes for code lengths (RFC 1951 3.2.2).
fn canonical(lens: []const u8, codes: []u32) void {
    var count: [16]u32 = @splat(0);
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var next: [16]u32 = undefined;
    var c: u32 = 0;
    for (1..16) |b| {
        c = (c + count[b - 1]) << 1;
        next[b] = c;
    }
    for (lens, 0..) |l, s| {
        if (l != 0) {
            codes[s] = next[l];
            next[l] += 1;
        }
    }
}

const Codes = struct {
    lit_lens: [288]u8,
    dist_lens: [32]u8,
    lit: [288]u32 = undefined,
    dist: [32]u32 = undefined,

    fn init(lit_lens: [288]u8, dist_lens: [32]u8) Codes {
        var c: Codes = .{ .lit_lens = lit_lens, .dist_lens = dist_lens };
        canonical(&c.lit_lens, &c.lit);
        canonical(&c.dist_lens, &c.dist);
        return c;
    }
    fn fixed() Codes {
        var l: [288]u8 = undefined;
        @memset(l[0..144], 8);
        @memset(l[144..256], 9);
        @memset(l[256..280], 7);
        @memset(l[280..288], 8);
        return init(l, @splat(5));
    }
    fn sym(c: *const Codes, w: *BitWriter, s: usize) !void {
        try w.code(c.lit[s], @intCast(c.lit_lens[s]));
    }
    fn tokens(c: *const Codes, w: *BitWriter, ts: []const Token) !void {
        for (ts) |t| switch (t) {
            .lit => |b| try c.sym(w, b),
            .match => |m| {
                const li = lenCode(m.len);
                try c.sym(w, 257 + li);
                try w.bits(m.len - len_base[li], len_extra[li]);
                const di = distCode(m.dist);
                try w.code(c.dist[di], @intCast(c.dist_lens[di]));
                try w.bits(m.dist - dist_base[di], dist_extra[di]);
            },
        };
        try c.sym(w, 256);
    }
};

fn fixedBlock(w: *BitWriter, ts: []const Token, final: bool) !void {
    try w.bits(@intFromBool(final), 1);
    try w.bits(1, 2);
    try Codes.fixed().tokens(w, ts);
}

/// Dynamic block header writing the given lengths with a flat 4-bit precode
/// (symbols 0..15, so any lengths are expressible, even invalid ones).
fn dynamicHeader(w: *BitWriter, final: bool, lit_lens: []const u8, dist_lens: []const u8) !void {
    try w.bits(@intFromBool(final), 1);
    try w.bits(2, 2);
    try w.bits(@intCast(lit_lens.len - 257), 5);
    try w.bits(@intCast(dist_lens.len - 1), 5);
    try w.bits(19 - 4, 4);
    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    for (order) |s| try w.bits(if (s < 16) 4 else 0, 3);
    for (lit_lens) |l| try w.code(l, 4);
    for (dist_lens) |l| try w.code(l, 4);
}

fn dynamicBlock(w: *BitWriter, ts: []const Token, final: bool, c: *const Codes, nlit: usize, ndist: usize) !void {
    try dynamicHeader(w, final, c.lit_lens[0..nlit], c.dist_lens[0..ndist]);
    try c.tokens(w, ts);
}

/// Random complete code lengths (<= 15) for `n` symbols: split random leaves of a
/// binary tree, preferring deep ones so long (subtable) codes show up.
fn randomLens(r: std.Random, lens: []u8) void {
    var depth: [288]u8 = undefined;
    depth[0] = 0;
    var leaves: usize = 1;
    while (leaves < lens.len) {
        var i = r.uintLessThan(usize, leaves);
        if (r.boolean()) { // deepest splittable leaf
            var best: usize = 0;
            for (0..leaves) |k| if (depth[k] < 15 and (depth[best] >= 15 or depth[k] > depth[best])) {
                best = k;
            };
            i = best;
        }
        if (depth[i] >= 15) continue;
        depth[i] += 1;
        depth[leaves] = depth[i];
        leaves += 1;
    }
    r.shuffle(u8, depth[0..leaves]);
    @memcpy(lens, depth[0..lens.len]);
}

fn randomTokens(r: std.Random, ts: *std.ArrayList(Token), n: usize, start_pos: usize) !usize {
    var pos = start_pos;
    for (0..n) |_| {
        if (pos == 0 or r.uintLessThan(u8, 3) == 0) {
            try ts.append(gpa, .{ .lit = r.int(u8) });
            pos += 1;
            continue;
        }
        const max_d: u16 = @intCast(@min(pos, 32768));
        const dist: u16 = switch (r.uintLessThan(u8, 4)) {
            0 => r.intRangeAtMost(u16, 1, @min(max_d, 64)),
            1 => max_d,
            else => r.intRangeAtMost(u16, 1, max_d),
        };
        const len: u16 = switch (r.uintLessThan(u8, 3)) {
            0 => 258,
            else => r.intRangeAtMost(u16, 3, 258),
        };
        try ts.append(gpa, .{ .match = .{ .len = len, .dist = dist } });
        pos += len;
    }
    return pos;
}

// ───────────────────────────── tests ─────────────────────────────

test "inflate: std compress levels, stored, huffman-only; all containers" {
    const sizes = [_]usize{ 0, 1, 2, 7, 100, 300, 1000, 33000, 70000, 300_000 };
    const levels = [_]Level{
        .stored,                         .huffman,
        .{ .opts = .level_1 },           .{ .opts = .level_2 },
        .{ .opts = .level_3 },           .{ .opts = .level_4 },
        .{ .opts = .level_5 },           .{ .opts = .level_6 },
        .{ .opts = .level_7 },           .{ .opts = .level_8 },
        .{ .opts = .level_9 },
    };
    for (std.enums.values(Gen), 0..) |g, gi| {
        for (sizes) |n| {
            const data = try genData(g, n, gi * 1000 + n);
            defer gpa.free(data);
            for (levels) |lv| {
                // all containers at a few sizes; zlib (cheapest) everywhere
                for ([_]inflate.Container{ .raw, .zlib, .gzip }) |c| {
                    if (c != .zlib and n > 1000 and n != 70000) continue;
                    const comp = try stdCompress(data, c, lv);
                    defer gpa.free(comp);
                    expectDecodes(c, comp, data) catch |e| {
                        std.debug.print("gen {t} n {d} level {any} container {t}\n", .{ g, n, lv, c });
                        return e;
                    };
                }
            }
        }
    }
}

test "inflate: fixed and dynamic blocks with every length/distance code, long codes, overlaps" {
    var rng: std.Random.DefaultPrng = .init(42);
    const r = rng.random();
    for (0..40) |iter| {
        var ts: std.ArrayList(Token) = .empty;
        defer ts.deinit(gpa);
        var w: BitWriter = .{};
        defer w.deinit();
        var pos: usize = 0;
        const nblocks = 1 + r.uintLessThan(usize, 4);
        var block_tokens: [5][2]usize = undefined;
        for (0..nblocks) |bi| {
            const t0 = ts.items.len;
            pos = try randomTokens(r, &ts, if (iter < 4) 3000 else r.uintLessThan(usize, 600), pos);
            block_tokens[bi] = .{ t0, ts.items.len };
        }
        for (0..nblocks) |bi| {
            const blk = ts.items[block_tokens[bi][0]..block_tokens[bi][1]];
            const final = bi + 1 == nblocks;
            switch (r.uintLessThan(u8, 3)) {
                0 => try fixedBlock(&w, blk, final),
                else => {
                    var ll: [288]u8 = @splat(0);
                    var dl: [32]u8 = @splat(0);
                    randomLens(r, ll[0..286]);
                    randomLens(r, dl[0..30]);
                    const c = Codes.init(ll, dl);
                    try dynamicBlock(&w, blk, final, &c, 286, 30);
                },
            }
        }
        try w.flush();
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(gpa);
        try apply(ts.items, &want);
        try expectDecodes(.raw, w.bytes.items, want.items);
        const s = (try stdDecompress(w.bytes.items, .raw)).?;
        defer gpa.free(s);
        try testing.expectEqualSlices(u8, want.items, s);
    }
}

test "inflate: every offset 1..64 x lengths, max distance, exact output sizes around the margins" {
    var rng: std.Random.DefaultPrng = .init(9);
    const r = rng.random();
    // overlapping copies: prefix of 64 random bytes, then (dist, len) matches
    for (1..65) |dist| {
        for ([_]u16{ 3, 4, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65, 100, 257, 258 }) |len| {
            var ts: std.ArrayList(Token) = .empty;
            defer ts.deinit(gpa);
            for (0..64) |_| try ts.append(gpa, .{ .lit = r.int(u8) });
            for (0..3) |_| try ts.append(gpa, .{ .match = .{ .len = len, .dist = @intCast(dist) } });
            try ts.append(gpa, .{ .lit = 1 });
            var w: BitWriter = .{};
            defer w.deinit();
            try fixedBlock(&w, ts.items, true);
            try w.flush();
            var want: std.ArrayList(u8) = .empty;
            defer want.deinit(gpa);
            try apply(ts.items, &want);
            try expectDecodes(.raw, w.bytes.items, want.items);
        }
    }
    // distance 32768 / length 258, output ending at every size around fast_out
    {
        var ts: std.ArrayList(Token) = .empty;
        defer ts.deinit(gpa);
        for (0..32768) |_| try ts.append(gpa, .{ .lit = r.int(u8) });
        for (0..20) |_| try ts.append(gpa, .{ .match = .{ .len = 258, .dist = 32768 } });
        var w: BitWriter = .{};
        defer w.deinit();
        try fixedBlock(&w, ts.items, true);
        try w.flush();
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(gpa);
        try apply(ts.items, &want);
        try expectDecodes(.raw, w.bytes.items, want.items);
    }
    // stream lengths 0..700 (std level 6 + stored), all output sizes across both margins
    for (0..700) |n| {
        const data = try genData(.text, n, n);
        defer gpa.free(data);
        for ([_]Level{ .{ .opts = .default }, .stored }) |lv| {
            const comp = try stdCompress(data, .raw, lv);
            defer gpa.free(comp);
            try expectDecodes(.raw, comp, data);
        }
    }
}

test "inflate: single-code and empty distance trees, literal-only dynamic block" {
    // dynamic block whose distance tree has a single 1-bit code (incomplete, allowed)
    var ll: [288]u8 = @splat(0);
    for (0..256) |i| ll[i] = 9; // 256 x 9 bits = 1/2 of the code space
    ll[256] = 2; // 1/4
    ll[257] = 3; // 1/8 (length 3)
    ll[258] = 3; // 1/8 (length 4)
    var dl: [32]u8 = @splat(0);
    dl[0] = 1;
    const c = Codes.init(ll, dl);
    const ts = [_]Token{ .{ .lit = 'a' }, .{ .lit = 'b' }, .{ .match = .{ .len = 3, .dist = 1 } }, .{ .match = .{ .len = 4, .dist = 1 } } };
    var w: BitWriter = .{};
    defer w.deinit();
    try dynamicBlock(&w, &ts, true, &c, 259, 1);
    try w.flush();
    try expectDecodes(.raw, w.bytes.items, "abbbbbbbb");

    // empty distance tree (all zero lengths): literals only
    var w2: BitWriter = .{};
    defer w2.deinit();
    const dl0: [32]u8 = @splat(0);
    const c2 = Codes.init(ll, dl0);
    const ts2 = [_]Token{ .{ .lit = 'x' }, .{ .lit = 'y' } };
    try dynamicBlock(&w2, &ts2, true, &c2, 259, 1);
    try w2.flush();
    try expectDecodes(.raw, w2.bytes.items, "xy");

    // ...but using a match with it is an error
    var w3: BitWriter = .{};
    defer w3.deinit();
    try dynamicHeader(&w3, true, c2.lit_lens[0..259], c2.dist_lens[0..1]);
    try c2.sym(&w3, 'x');
    try c2.sym(&w3, 257);
    try w3.bits(0, 8);
    try w3.flush();
    var out: [16]u8 = undefined;
    try testing.expectError(error.InvalidCode, inflate.decompress(.raw, w3.bytes.items, &out, .{}));
}

test "inflate: external gzip (gzip -1 / -9, FNAME, multi-member)" {
    const files = .{ "art1.gz", "art9.gz", "grad9.gz", "text1.gz", "text9.gz", "jpg6.gz" };
    inline for (files) |f| {
        const gz = @embedFile("testdata/" ++ f);
        const want = (try stdDecompress(gz, .gzip)).?;
        defer gpa.free(want);
        try expectDecodes(.gzip, gz, want);
    }
    // two members back to back decode as their concatenation
    const multi = @embedFile("testdata/multi.gz");
    const a = (try stdDecompress(@embedFile("testdata/art1.gz"), .gzip)).?;
    defer gpa.free(a);
    const b = (try stdDecompress(@embedFile("testdata/grad9.gz"), .gzip)).?;
    defer gpa.free(b);
    const ab = try std.mem.concat(gpa, u8, &.{ a, b });
    defer gpa.free(ab);
    try expectDecodes(.gzip, multi, ab);
    // single-member mode stops after the first one
    const out = try gpa.alloc(u8, ab.len);
    defer gpa.free(out);
    const r = try inflate.decompress(.gzip, multi, out, .{ .multi_member = false });
    try testing.expectEqual(a.len, r.out_len);
    try testing.expectEqual(@embedFile("testdata/art1.gz").len, r.in_len);
    // trailing garbage after a member is left unconsumed
    const junk = try std.mem.concat(gpa, u8, &.{ @embedFile("testdata/art9.gz"), "\x00\x00junk" });
    defer gpa.free(junk);
    const r2 = try inflate.decompress(.gzip, junk, out, .{});
    try testing.expectEqual(junk.len - 6, r2.in_len);
}

test "inflate: gzip header fields (FEXTRA, FNAME, FCOMMENT, FHCRC)" {
    const data = "hello hello hello gzip header fields";
    const raw = try stdCompress(data, .raw, .{ .opts = .default });
    defer gpa.free(raw);
    var hdr: std.ArrayList(u8) = .empty;
    defer hdr.deinit(gpa);
    try hdr.appendSlice(gpa, &.{ 0x1f, 0x8b, 8, 0x04 | 0x08 | 0x10 | 0x02, 0, 0, 0, 0, 0, 3 });
    try hdr.appendSlice(gpa, &.{ 5, 0, 'a', 'b', 'c', 'd', 'e' });
    try hdr.appendSlice(gpa, "name.bin\x00");
    try hdr.appendSlice(gpa, "a comment\x00");
    const hcrc: u16 = @truncate(inflate.crc32.hash(hdr.items));
    try hdr.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, hcrc)));
    try hdr.appendSlice(gpa, raw);
    try hdr.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, inflate.crc32.hash(data))));
    try hdr.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, data.len)));
    try expectDecodes(.gzip, hdr.items, data);
    // a wrong header CRC is rejected (only when verifying)
    hdr.items[10 + 7 + 9 + 10] ^= 1;
    var out: [data.len]u8 = undefined;
    try testing.expectError(error.BadGzipHeader, inflate.decompress(.gzip, hdr.items, &out, .{}));
    _ = try inflate.decompress(.gzip, hdr.items, &out, .{ .verify = false });
}

test "inflate: PNG IDAT zlib streams from the test images" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, "src/Data/Read/png", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |ent| {
        if (!std.mem.endsWith(u8, ent.name, ".png")) continue;
        const png = try dir.readFileAlloc(io, ent.name, gpa, .limited(64 << 20));
        defer gpa.free(png);
        var idat: std.ArrayList(u8) = .empty;
        defer idat.deinit(gpa);
        var p: usize = 8;
        while (p + 12 <= png.len) {
            const len = std.mem.readInt(u32, png[p..][0..4], .big);
            if (p + 12 + len > png.len) break;
            if (std.mem.eql(u8, png[p + 4 ..][0..4], "IDAT")) try idat.appendSlice(gpa, png[p + 8 ..][0..len]);
            p += 12 + len;
        }
        if (idat.items.len == 0) continue;
        const want = (try stdDecompress(idat.items, .zlib)) orelse continue; // deliberately broken files
        defer gpa.free(want);
        expectDecodes(.zlib, idat.items, want) catch |e| {
            std.debug.print("{s}\n", .{ent.name});
            return e;
        };
        n += 1;
    }
    try testing.expect(n > 20);
}

test "inflate: malformed input" {
    var out: [4096]u8 = undefined;
    const data = try genData(.text, 3000, 1);
    defer gpa.free(data);
    // truncation at every byte, every container: always an error, never a crash
    for ([_]inflate.Container{ .raw, .zlib, .gzip }) |c| {
        for ([_]Level{ .{ .opts = .default }, .stored, .huffman }) |lv| {
            const comp = try stdCompress(data, c, lv);
            defer gpa.free(comp);
            for (0..comp.len) |cut| {
                if (inflate.decompress(c, comp[0..cut], &out, .{})) |_| {
                    std.debug.print("{t} cut {d}/{d} decoded\n", .{ c, cut, comp.len });
                    return error.TestUnexpectedResult;
                } else |_| {}
            }
            // every output size that is too small
            for (0..data.len) |k| try testing.expectError(error.OutputTooSmall, inflate.decompress(c, comp, out[0..k], .{}));
        }
    }
    // empty input
    for ([_]inflate.Container{ .raw, .zlib, .gzip }) |c| try testing.expectError(error.EndOfStream, inflate.decompress(c, "", &out, .{}));
    // block type 3
    try testing.expectError(error.InvalidBlockType, inflate.decompress(.raw, &.{0x07}, &out, .{}));
    // stored block with bad NLEN
    try testing.expectError(error.WrongStoredBlockNlen, inflate.decompress(.raw, &.{ 0x01, 3, 0, 0xfc, 0xfe, 'a', 'b', 'c' }, &out, .{}));
    // distance beyond the start of the output
    {
        var w: BitWriter = .{};
        defer w.deinit();
        try fixedBlock(&w, &.{ .{ .lit = 'a' }, .{ .match = .{ .len = 3, .dist = 2 } } }, true);
        try w.flush();
        try testing.expectError(error.InvalidMatch, inflate.decompress(.raw, w.bytes.items, &out, .{}));
        // same, deep inside a fast-path-sized stream
        var w2: BitWriter = .{};
        defer w2.deinit();
        var ts: [2000]Token = @splat(.{ .lit = 'q' });
        ts[1999] = .{ .match = .{ .len = 10, .dist = 2000 } };
        try fixedBlock(&w2, &ts, true);
        try w2.flush();
        try testing.expectError(error.InvalidMatch, inflate.decompress(.raw, w2.bytes.items, &out, .{}));
    }
    // fixed-code length symbols 286/287 and distance codes 30/31
    inline for (.{ 286, 287 }) |sym| {
        var w: BitWriter = .{};
        defer w.deinit();
        try w.bits(1, 1);
        try w.bits(1, 2);
        try w.code('a' + 0x30, 8);
        try w.code(0xc0 + (sym - 280), 8);
        try w.bits(0, 16);
        try w.flush();
        try testing.expectError(error.InvalidCode, inflate.decompress(.raw, w.bytes.items, &out, .{}));
    }
    inline for (.{ 30, 31 }) |dc| {
        var w: BitWriter = .{};
        defer w.deinit();
        try w.bits(1, 1);
        try w.bits(1, 2);
        try w.code('a' + 0x30, 8);
        try w.code(1, 7); // length 3
        try w.code(dc, 5);
        try w.bits(0, 24);
        try w.flush();
        try testing.expectError(error.InvalidCode, inflate.decompress(.raw, w.bytes.items, &out, .{}));
    }
    // over-subscribed / incomplete literal trees, missing end-of-block, bad repeat
    {
        var ll: [286]u8 = @splat(8); // 286 x 1/256 > 1
        var w: BitWriter = .{};
        defer w.deinit();
        try dynamicHeader(&w, true, &ll, &.{1});
        try w.bits(0, 32);
        try w.flush();
        try testing.expectError(error.OversubscribedHuffmanTree, inflate.decompress(.raw, w.bytes.items, &out, .{}));

        @memset(&ll, 9); // 286 x 1/512 < 1
        var w2: BitWriter = .{};
        defer w2.deinit();
        try dynamicHeader(&w2, true, &ll, &.{1});
        try w2.bits(0, 32);
        try w2.flush();
        try testing.expectError(error.IncompleteHuffmanTree, inflate.decompress(.raw, w2.bytes.items, &out, .{}));

        @memset(&ll, 0);
        ll['a'] = 1;
        ll['b'] = 1;
        var w3: BitWriter = .{};
        defer w3.deinit();
        try dynamicHeader(&w3, true, ll[0..257], &.{1});
        try w3.bits(0, 32);
        try w3.flush();
        try testing.expectError(error.MissingEndOfBlockCode, inflate.decompress(.raw, w3.bytes.items, &out, .{}));

        // incomplete distance tree (two codes of length 2)
        var ll2: [288]u8 = @splat(0);
        ll2[256] = 1;
        ll2['a'] = 1;
        var w4: BitWriter = .{};
        defer w4.deinit();
        try dynamicHeader(&w4, true, ll2[0..257], &.{ 2, 2 });
        try w4.bits(0, 32);
        try w4.flush();
        try testing.expectError(error.IncompleteHuffmanTree, inflate.decompress(.raw, w4.bytes.items, &out, .{}));

        // HLIT > 286
        var w5: BitWriter = .{};
        defer w5.deinit();
        try w5.bits(1, 1);
        try w5.bits(2, 2);
        try w5.bits(30, 5);
        try w5.bits(0, 32);
        try w5.flush();
        try testing.expectError(error.InvalidDynamicBlockHeader, inflate.decompress(.raw, w5.bytes.items, &out, .{}));

        // over-subscribed precode (all 19 lengths = 1)
        var w6: BitWriter = .{};
        defer w6.deinit();
        try w6.bits(1, 1);
        try w6.bits(2, 2);
        try w6.bits(0, 5);
        try w6.bits(0, 5);
        try w6.bits(15, 4);
        for (0..19) |_| try w6.bits(1, 3);
        try w6.bits(0, 32);
        try w6.flush();
        try testing.expectError(error.OversubscribedHuffmanTree, inflate.decompress(.raw, w6.bytes.items, &out, .{}));
    }
    // checksums: bad CRC, bad ISIZE, bad Adler, bad zlib header
    {
        const gz = try stdCompress(data, .gzip, .{ .opts = .default });
        defer gpa.free(gz);
        var o2: [3000]u8 = undefined;
        gz[gz.len - 8] ^= 1;
        try testing.expectError(error.WrongGzipChecksum, inflate.decompress(.gzip, gz, &o2, .{}));
        _ = try inflate.decompress(.gzip, gz, &o2, .{ .verify = false });
        gz[gz.len - 8] ^= 1;
        gz[gz.len - 4] ^= 1;
        try testing.expectError(error.WrongGzipSize, inflate.decompress(.gzip, gz, &o2, .{}));
        gz[gz.len - 4] ^= 1;
        gz[3] = 0x80; // reserved flag
        try testing.expectError(error.BadGzipHeader, inflate.decompress(.gzip, gz, &o2, .{}));
        const z = try stdCompress(data, .zlib, .{ .opts = .default });
        defer gpa.free(z);
        z[z.len - 1] ^= 1;
        try testing.expectError(error.WrongZlibChecksum, inflate.decompress(.zlib, z, &o2, .{}));
        z[z.len - 1] ^= 1;
        z[1] ^= 1; // FCHECK
        try testing.expectError(error.BadZlibHeader, inflate.decompress(.zlib, z, &o2, .{}));
    }
}

test "inflate: bit-flip fuzz against std" {
    var rng: std.Random.DefaultPrng = .init(0xf1f1);
    const r = rng.random();
    const out = try gpa.alloc(u8, 1 << 18);
    defer gpa.free(out);
    var streams: std.ArrayList([]u8) = .empty;
    defer {
        for (streams.items) |s| gpa.free(s);
        streams.deinit(gpa);
    }
    for ([_]Gen{ .text, .runs, .words16, .mixed }, 0..) |g, i| {
        const data = try genData(g, 2000 + i * 3000, i);
        defer gpa.free(data);
        for ([_]Level{ .{ .opts = .level_1 }, .{ .opts = .default }, .huffman, .stored }) |lv|
            try streams.append(gpa, try stdCompress(data, .raw, lv));
    }
    // hand-built: fixed and long-code dynamic blocks
    {
        var ts: std.ArrayList(Token) = .empty;
        defer ts.deinit(gpa);
        _ = try randomTokens(r, &ts, 400, 0);
        var w: BitWriter = .{};
        defer w.deinit();
        try fixedBlock(&w, ts.items, true);
        try w.flush();
        try streams.append(gpa, try gpa.dupe(u8, w.bytes.items));
        var ll: [288]u8 = @splat(0);
        var dl: [32]u8 = @splat(0);
        randomLens(r, ll[0..286]);
        randomLens(r, dl[0..30]);
        const c = Codes.init(ll, dl);
        ts.clearRetainingCapacity();
        _ = try randomTokens(r, &ts, 400, 1000);
        // tokens assume 1000 bytes of history; prepend them as a stored block
        var w0: BitWriter = .{};
        defer w0.deinit();
        try w0.bits(0, 3);
        try w0.flush();
        try w0.bytes.appendSlice(gpa, &.{ 0xe8, 0x03, 0x17, 0xfc });
        for (0..1000) |k| try w0.bytes.append(gpa, @truncate(k * 7));
        try dynamicBlock(&w0, ts.items, true, &c, 286, 30);
        try w0.flush();
        try streams.append(gpa, try gpa.dupe(u8, w0.bytes.items));
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var ok: usize = 0;
    for (0..3000) |iter| {
        const src = streams.items[iter % streams.items.len];
        buf.clearRetainingCapacity();
        try buf.appendSlice(gpa, src);
        const flips = 1 + r.uintLessThan(usize, 3);
        for (0..flips) |_| {
            // bias toward the header, where the trees live
            const at = if (r.boolean()) r.uintLessThan(usize, @min(buf.items.len, 64)) else r.uintLessThan(usize, buf.items.len);
            buf.items[at] ^= @as(u8, 1) << r.int(u3);
        }
        if (r.uintLessThan(u8, 8) == 0) buf.items.len = r.uintLessThan(usize, buf.items.len);
        const mine = inflate.decompress(.raw, buf.items, out, .{}) catch continue;
        const theirs = (try stdDecompress(buf.items[0..mine.in_len], .raw)) orelse {
            std.debug.print("iter {d}: std rejects a stream inflate accepted\n", .{iter});
            return error.TestUnexpectedResult;
        };
        defer gpa.free(theirs);
        try testing.expectEqualSlices(u8, theirs, out[0..mine.out_len]);
        ok += 1;
    }
    try testing.expect(ok > 0);
}

test "inflate: real .nii.gz (if present) matches std" {
    const path = "C:/Users/bphil/code/zig/Segmentation/data/ds004696/sub-01/anat/sub-01_ses-mri01_T1w.nii.gz";
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const gz = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30)) catch return error.SkipZigTest;
    defer gpa.free(gz);
    const want = (try stdDecompress(gz, .gzip)).?;
    defer gpa.free(want);
    try testing.expectEqual(std.mem.readInt(u32, gz[gz.len - 4 ..][0..4], .little), @as(u32, @truncate(want.len)));
    const out = try gpa.alloc(u8, want.len);
    defer gpa.free(out);
    const r = try inflate.decompressSplit(.gzip, gz, out[0..352], out[352..], .{});
    try testing.expectEqual(want.len, r.out_len);
    try testing.expect(std.mem.eql(u8, want, out));
}
