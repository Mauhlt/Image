//! VP8L prefix codes: canonical Huffman (deflate-style), bits stored LSB-first.
const std = @import("std");
const Error = @import("../error.zig").Error;
const BitReader = @import("bitreader.zig");
const BitWriter = @import("bitwriter.zig");

pub const MAX_LEN = 15;
const ROOT_BITS = 8;
pub const CODE_LENGTH_CODES = 19;
pub const CODE_LENGTH_ORDER = [CODE_LENGTH_CODES]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

// ───────────────────────────── Decode ─────────────────────────────

/// Two-level lookup tables (as zlib and libwebp do): the next ROOT_BITS stream
/// bits index the root table; codes longer than that continue in a sub-table
/// for their first ROOT_BITS bits, indexed by the following bits.
pub const Tree = struct {
    /// root table, then the sub-tables. An entry is (len << 16) | value:
    /// in the root, len <= ROOT_BITS gives the code length and symbol, and a
    /// larger len links to a sub-table of 2^(len - ROOT_BITS) entries at
    /// `value`; sub-table entries hold the remaining length and the symbol.
    /// len 0: no code starts with these bits.
    table: []u32 = &.{},
    /// set when the code has a single symbol (0 bits per symbol)
    single: ?u16 = null,

    pub fn fromLengths(scratch: std.mem.Allocator, lengths: []const u8) !Tree {
        var counts: [MAX_LEN + 1]u16 = @splat(0);
        var n_used: usize = 0;
        var last: u16 = 0;
        for (lengths, 0..) |len, s| {
            if (len > MAX_LEN) return Error.InvalidHuffmanCode;
            if (len != 0) {
                n_used += 1;
                last = @intCast(s);
                counts[len] += 1;
            }
        }
        if (n_used == 0) return Error.InvalidHuffmanCode;
        if (n_used == 1) return .{ .single = last };
        // over-subscription check
        var left: i32 = 1;
        for (1..MAX_LEN + 1) |len| {
            left = (left << 1) - counts[len];
            if (left < 0) return Error.InvalidHuffmanCode;
        }

        // canonical first code of each length
        var first_code: [MAX_LEN + 1]u16 = @splat(0);
        var code: u16 = 0;
        for (1..MAX_LEN + 1) |len| {
            first_code[len] = code;
            code = (code + counts[len]) << 1;
        }

        // sub-table sizes: the longest code under each root prefix
        var sub_bits: [1 << ROOT_BITS]u8 = @splat(0);
        var next_code = first_code;
        for (lengths) |len| if (len > ROOT_BITS) {
            const prefix = reversedCode(next_code[len], len) & ((1 << ROOT_BITS) - 1);
            next_code[len] += 1;
            sub_bits[prefix] = @max(sub_bits[prefix], len - ROOT_BITS);
        };
        var size: usize = 1 << ROOT_BITS;
        for (sub_bits) |b| {
            if (b > 0) size += @as(usize, 1) << @intCast(b);
        }
        const table = try scratch.alloc(u32, size);
        @memset(table, 0);
        size = 1 << ROOT_BITS;
        for (sub_bits, 0..) |b, prefix| if (b > 0) {
            table[prefix] = (@as(u32, ROOT_BITS + b) << 16) | @as(u32, @intCast(size));
            size += @as(usize, 1) << @intCast(b);
        };

        next_code = first_code;
        for (lengths, 0..) |len, s| {
            if (len == 0) continue;
            const rev = reversedCode(next_code[len], len);
            next_code[len] += 1;
            if (len <= ROOT_BITS) {
                fill(table[0 .. 1 << ROOT_BITS], rev, len, (@as(u32, len) << 16) | @as(u32, @intCast(s)));
            } else {
                const link = table[rev & ((1 << ROOT_BITS) - 1)];
                const sub = table[link & 0xFFFF ..][0 .. @as(usize, 1) << @intCast((link >> 16) - ROOT_BITS)];
                const rest = len - ROOT_BITS;
                fill(sub, rev >> ROOT_BITS, rest, (@as(u32, rest) << 16) | @as(u32, @intCast(s)));
            }
        }
        return .{ .table = table };
    }

    /// The code's bits in stream order (its first bit, the MSB, at bit 0).
    fn reversedCode(code: u16, len: u8) u32 {
        return @bitReverse(code) >> @intCast(16 - len);
    }

    /// Every entry of `t` whose low `len` index bits are `index`.
    fn fill(t: []u32, index: u32, len: u8, entry: u32) void {
        var i: usize = index;
        while (i < t.len) : (i += @as(usize, 1) << @intCast(len)) t[i] = entry;
    }

    pub fn decode(self: *const Tree, br: *BitReader) Error!u16 {
        if (self.single) |s| return s;
        const bits = br.peek(MAX_LEN);
        var entry = self.table[bits & ((1 << ROOT_BITS) - 1)];
        var len = entry >> 16;
        if (len > ROOT_BITS) {
            const sub_mask = (@as(u32, 1) << @intCast(len - ROOT_BITS)) - 1;
            entry = self.table[(entry & 0xFFFF) + ((bits >> ROOT_BITS) & sub_mask)];
            len = entry >> 16;
            if (len == 0) return Error.InvalidHuffmanCode;
            len += ROOT_BITS;
        } else if (len == 0) return Error.InvalidHuffmanCode;
        br.consume(@intCast(len));
        return @truncate(entry);
    }
};

/// Reads a prefix code description for an alphabet of `alphabet_size` symbols.
pub fn readTree(scratch: std.mem.Allocator, br: *BitReader, alphabet_size: usize) !Tree {
    const lengths = try scratch.alloc(u8, alphabet_size);
    defer scratch.free(lengths);
    @memset(lengths, 0);

    if (br.readBit()) { // simple code
        const n_symbols = br.readBits(1) + 1;
        const first_8bits = br.readBits(1);
        const s0 = br.readBits(if (first_8bits == 1) 8 else 1);
        if (s0 >= alphabet_size) return Error.InvalidHuffmanCode;
        lengths[s0] = 1;
        if (n_symbols == 2) {
            const s1 = br.readBits(8);
            if (s1 >= alphabet_size) return Error.InvalidHuffmanCode;
            lengths[s1] = 1;
        }
    } else { // normal code
        var cl_lengths: [CODE_LENGTH_CODES]u8 = @splat(0);
        const n_codes = br.readBits(4) + 4;
        for (0..n_codes) |i| cl_lengths[CODE_LENGTH_ORDER[i]] = @intCast(br.readBits(3));
        const cl_tree: Tree = try .fromLengths(scratch, &cl_lengths);
        defer scratch.free(cl_tree.table);

        var max_symbol = alphabet_size;
        if (br.readBit()) {
            const length_nbits: u6 = @intCast(2 + 2 * br.readBits(3));
            max_symbol = 2 + br.readBits(length_nbits);
            if (max_symbol > alphabet_size) return Error.InvalidHuffmanCode;
        }

        var prev_len: u8 = 8;
        var s: usize = 0;
        while (s < alphabet_size) {
            if (max_symbol == 0) break;
            max_symbol -= 1;
            const code_len = try cl_tree.decode(br);
            if (code_len < 16) {
                lengths[s] = @intCast(code_len);
                s += 1;
                if (code_len != 0) prev_len = @intCast(code_len);
                continue;
            }
            const repeat: usize, const value: u8 = switch (code_len) {
                16 => .{ 3 + br.readBits(2), prev_len },
                17 => .{ 3 + br.readBits(3), 0 },
                18 => .{ 11 + br.readBits(7), 0 },
                else => return Error.InvalidHuffmanCode,
            };
            if (s + repeat > alphabet_size) return Error.InvalidHuffmanCode;
            @memset(lengths[s..][0..repeat], value);
            s += repeat;
        }
    }
    try br.check();
    return .fromLengths(scratch, lengths);
}

// ───────────────────────────── Encode ─────────────────────────────

/// Builds length-limited Huffman code lengths from symbol frequencies.
pub fn buildLengths(gpa: std.mem.Allocator, freqs: []const u32, max_len: u4, lengths: []u8) !void {
    @memset(lengths, 0);
    const Node = struct { freq: u64, parent: u32 = std.math.maxInt(u32) };

    const scaled = try gpa.dupe(u32, freqs);
    defer gpa.free(scaled);
    var leaves: std.ArrayList(u32) = .empty; // symbol ids sorted by freq
    defer leaves.deinit(gpa);
    var nodes: std.ArrayList(Node) = .empty;
    defer nodes.deinit(gpa);

    while (true) {
        leaves.clearRetainingCapacity();
        nodes.clearRetainingCapacity();
        for (scaled, 0..) |f, s| if (f > 0) try leaves.append(gpa, @intCast(s));
        if (leaves.items.len == 0) return;
        if (leaves.items.len == 1) {
            lengths[leaves.items[0]] = 1;
            return;
        }
        std.mem.sort(u32, leaves.items, scaled, struct {
            fn lt(ctx: []const u32, a: u32, b: u32) bool {
                return ctx[a] < ctx[b] or (ctx[a] == ctx[b] and a < b);
            }
        }.lt);
        // nodes[0..n) = leaves (sorted), then internal nodes appended in increasing freq order
        const n = leaves.items.len;
        for (leaves.items) |s| try nodes.append(gpa, .{ .freq = scaled[s] });
        var li: usize = 0; // next unused leaf
        var ii: usize = n; // next unused internal node
        for (0..n - 1) |_| {
            var pick: [2]usize = undefined;
            for (&pick) |*p| {
                if (li < n and (ii >= nodes.items.len or nodes.items[li].freq <= nodes.items[ii].freq)) {
                    p.* = li;
                    li += 1;
                } else {
                    p.* = ii;
                    ii += 1;
                }
            }
            const parent: u32 = @intCast(nodes.items.len);
            try nodes.append(gpa, .{ .freq = nodes.items[pick[0]].freq + nodes.items[pick[1]].freq });
            nodes.items[pick[0]].parent = parent;
            nodes.items[pick[1]].parent = parent;
        }
        var too_long = false;
        for (leaves.items, 0..) |s, i| {
            var depth: usize = 0;
            var p = nodes.items[i].parent;
            while (p != std.math.maxInt(u32)) : (p = nodes.items[p].parent) depth += 1;
            if (depth > max_len) too_long = true;
            lengths[s] = @intCast(@min(depth, 255));
        }
        if (!too_long) return;
        // flatten the distribution and retry
        for (scaled) |*f| if (f.* > 0) {
            f.* = @max(1, f.* >> 1);
        };
    }
}

/// Canonical codes (MSB-first) for given lengths.
pub fn codesFromLengths(lengths: []const u8, codes: []u16) void {
    var counts: [MAX_LEN + 1]u16 = @splat(0);
    for (lengths) |l| counts[l] += 1;
    counts[0] = 0;
    var next: [MAX_LEN + 1]u16 = @splat(0);
    var code: u16 = 0;
    for (1..MAX_LEN + 1) |len| {
        next[len] = code;
        code = (code + counts[len]) << 1;
    }
    for (lengths, codes) |l, *c| {
        if (l == 0) continue;
        c.* = next[l];
        next[l] += 1;
    }
}

/// An encoder-side code: lengths + codes; `zero_bits` when only one symbol is used.
pub const Code = struct {
    lengths: []u8,
    codes: []u16,
    zero_bits: bool = false,

    pub fn deinit(self: Code, gpa: std.mem.Allocator) void {
        gpa.free(self.lengths);
        gpa.free(self.codes);
    }

    pub fn write(self: *const Code, bw: *BitWriter, symbol: usize) !void {
        if (self.zero_bits) return;
        std.debug.assert(self.lengths[symbol] != 0);
        try bw.writeCode(self.codes[symbol], @intCast(self.lengths[symbol]));
    }
};

/// Builds a code from `freqs` and writes its description to the stream.
pub fn writeTree(gpa: std.mem.Allocator, bw: *BitWriter, freqs: []const u32) !Code {
    const n = freqs.len;
    var code: Code = .{
        .lengths = try gpa.alloc(u8, n),
        .codes = try gpa.alloc(u16, n),
    };
    errdefer code.deinit(gpa);
    @memset(code.lengths, 0);
    @memset(code.codes, 0);

    var used: [3]usize = undefined;
    var n_used: usize = 0;
    for (freqs, 0..) |f, s| if (f > 0) {
        if (n_used < used.len) used[n_used] = s;
        n_used += 1;
    };

    // simple codes: <= 2 symbols, all < 256
    if (n_used <= 2 and (n_used == 0 or used[n_used - 1] < 256)) {
        const s0: u32 = if (n_used == 0) 0 else @intCast(used[0]);
        try bw.writeBits(1, 1); // simple
        try bw.writeBits(@intCast(@max(n_used, 1) - 1), 1);
        if (s0 > 1) {
            try bw.writeBits(1, 1);
            try bw.writeBits(s0, 8);
        } else {
            try bw.writeBits(0, 1);
            try bw.writeBits(s0, 1);
        }
        if (n_used == 2) {
            try bw.writeBits(@intCast(used[1]), 8);
            code.lengths[used[0]] = 1;
            code.lengths[used[1]] = 1;
            codesFromLengths(code.lengths, code.codes);
        } else {
            code.zero_bits = true;
        }
        return code;
    }

    try buildLengths(gpa, freqs, MAX_LEN, code.lengths);
    codesFromLengths(code.lengths, code.codes);
    code.zero_bits = n_used == 1;

    // tokenize the lengths (17 / 18 for zero runs)
    const Token = struct { sym: u8, extra: u8 = 0 };
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(gpa);
    var i: usize = 0;
    while (i < n) {
        const l = code.lengths[i];
        if (l != 0) {
            try tokens.append(gpa, .{ .sym = l });
            i += 1;
            continue;
        }
        var run: usize = 1;
        while (i + run < n and code.lengths[i + run] == 0) run += 1;
        i += run;
        while (run > 0) {
            if (run >= 11) {
                const r = @min(run, 138);
                try tokens.append(gpa, .{ .sym = 18, .extra = @intCast(r - 11) });
                run -= r;
            } else if (run >= 3) {
                try tokens.append(gpa, .{ .sym = 17, .extra = @intCast(run - 3) });
                run = 0;
            } else {
                try tokens.append(gpa, .{ .sym = 0 });
                run -= 1;
            }
        }
    }

    var cl_freqs: [CODE_LENGTH_CODES]u32 = @splat(0);
    for (tokens.items) |t| cl_freqs[t.sym] += 1;
    var cl_lengths: [CODE_LENGTH_CODES]u8 = undefined;
    try buildLengths(gpa, &cl_freqs, 7, &cl_lengths);
    var cl_codes: [CODE_LENGTH_CODES]u16 = @splat(0);
    codesFromLengths(&cl_lengths, &cl_codes);
    var cl_used: usize = 0;
    for (cl_lengths) |l| cl_used += @intFromBool(l != 0);

    var n_codes: usize = CODE_LENGTH_CODES;
    while (n_codes > 4 and cl_lengths[CODE_LENGTH_ORDER[n_codes - 1]] == 0) n_codes -= 1;

    try bw.writeBits(0, 1); // normal
    try bw.writeBits(@intCast(n_codes - 4), 4);
    for (CODE_LENGTH_ORDER[0..n_codes]) |s| try bw.writeBits(cl_lengths[s], 3);
    try bw.writeBits(0, 1); // max_symbol = alphabet size
    for (tokens.items) |t| {
        if (cl_used > 1) try bw.writeCode(cl_codes[t.sym], @intCast(cl_lengths[t.sym]));
        switch (t.sym) {
            17 => try bw.writeBits(t.extra, 3),
            18 => try bw.writeBits(t.extra, 7),
            else => {},
        }
    }
    return code;
}

test "huffman write/read round trip" {
    const gpa = std.testing.allocator;
    var freqs: [280]u32 = @splat(0);
    for (0..280) |s| freqs[s] = if (s % 7 == 0) @intCast(1 + s * s) else 0;
    freqs[3] = 100000;

    var bw: BitWriter = .{ .gpa = gpa };
    defer bw.deinit();
    const code = try writeTree(gpa, &bw, &freqs);
    defer code.deinit(gpa);
    const syms = [_]usize{ 0, 3, 7, 14, 273, 3, 3 };
    for (syms) |s| try code.write(&bw, s);
    const bytes = try bw.finish();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var br: BitReader = .{ .data = bytes };
    const tree = try readTree(arena.allocator(), &br, 280);
    for (syms) |s| try std.testing.expectEqual(@as(u16, @intCast(s)), try tree.decode(&br));
}

test "huffman length limit" {
    const gpa = std.testing.allocator;
    var freqs: [40]u32 = undefined;
    var f: u32 = 1;
    for (&freqs) |*x| {
        x.* = f;
        f = @min(f * 2, 1 << 30);
    }
    var lengths: [40]u8 = undefined;
    try buildLengths(gpa, &freqs, 15, &lengths);
    for (lengths) |l| try std.testing.expect(l >= 1 and l <= 15);
}
