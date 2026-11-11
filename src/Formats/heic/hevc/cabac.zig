//! CABAC: the context-adaptive binary arithmetic decoder (H.265 9.3), with
//! the contexts of intra (I) slices.
//!
//! The engine is the spec's: 9-bit ivlCurrRange / ivlOffset, renormalized one
//! bit at a time, so the bit position is always exactly the spec's (needed to
//! find PCM samples after a pcm_flag).
const std = @import("std");
const tables = @import("tables.zig");

/// Context variables of an I slice, in syntax element groups (Table 9-4).
pub const Contexts = struct {
    sao_merge: [1]u8,
    sao_type: [1]u8,
    split_cu: [3]u8,
    transquant_bypass: [1]u8,
    part_mode: [1]u8,
    prev_intra_luma_pred: [1]u8,
    intra_chroma_pred_mode: [1]u8,
    split_transform: [3]u8,
    cbf_luma: [2]u8,
    cbf_chroma: [4]u8,
    cu_qp_delta_abs: [2]u8,
    transform_skip: [2]u8, // luma, chroma
    last_x_prefix: [18]u8,
    last_y_prefix: [18]u8,
    coded_sub_block: [4]u8,
    sig_coeff: [42]u8,
    greater1: [24]u8,
    greater2: [6]u8,

    /// initValue for initType 0 (I slices), Tables 9-5 .. 9-37.
    const init_values: Contexts = .{
        .sao_merge = .{153},
        .sao_type = .{200},
        .split_cu = .{ 139, 141, 157 },
        .transquant_bypass = .{154},
        .part_mode = .{184},
        .prev_intra_luma_pred = .{184},
        .intra_chroma_pred_mode = .{63},
        .split_transform = .{ 153, 138, 138 },
        .cbf_luma = .{ 111, 141 },
        .cbf_chroma = .{ 94, 138, 182, 154 },
        .cu_qp_delta_abs = .{ 154, 154 },
        .transform_skip = .{ 139, 139 },
        .last_x_prefix = last_prefix_init,
        .last_y_prefix = last_prefix_init,
        .coded_sub_block = .{ 91, 171, 134, 141 },
        .sig_coeff = .{
            111, 111, 125, 110, 110, 94,  124, 108, 124, 107, 125, 141, 179, 153,
            125, 107, 125, 141, 179, 153, 125, 107, 125, 141, 179, 153, 125, 140,
            139, 182, 182, 152, 136, 152, 136, 153, 136, 139, 111, 136, 139, 111,
        },
        .greater1 = .{
            140, 92,  137, 138, 140, 152, 138, 139, 153, 74,  149, 92,
            139, 107, 122, 152, 140, 179, 166, 182, 140, 227, 122, 197,
        },
        .greater2 = .{ 138, 153, 136, 167, 152, 152 },
    };
    const last_prefix_init = [18]u8{ 110, 110, 124, 125, 140, 153, 125, 127, 140, 109, 111, 143, 127, 111, 79, 108, 123, 63 };

    /// 9.3.2.2: state = (pStateIdx << 1) | valMps from initValue and SliceQpY.
    pub fn init(qp: i32) Contexts {
        var c: Contexts = init_values;
        const bytes: *[@sizeOf(Contexts)]u8 = @ptrCast(&c);
        const q = std.math.clamp(qp, 0, 51);
        for (bytes) |*b| {
            const slope: i32 = @as(i32, b.* >> 4) * 5 - 45;
            const offset: i32 = (@as(i32, b.* & 15) << 3) - 16;
            const pre = std.math.clamp(((slope * q) >> 4) + offset, 1, 126);
            b.* = if (pre <= 63) @intCast((63 - pre) << 1) else @intCast(((pre - 64) << 1) | 1);
        }
        return c;
    }
};

pub const Decoder = struct {
    data: []const u8,
    /// next bit to read, in bits
    pos: usize,
    range: u32 = 510,
    offset: u32 = 0,

    /// 9.3.2.5: starts decoding at byte `start` of `data`.
    pub fn init(data: []const u8, start: usize) Decoder {
        var d: Decoder = .{ .data = data, .pos = start * 8 };
        for (0..9) |_| d.offset = (d.offset << 1) | d.readBit();
        return d;
    }

    fn readBit(d: *Decoder) u32 {
        // past the end: zeros (only malformed streams get there)
        const b: u32 = if (d.pos < d.data.len * 8) (d.data[d.pos >> 3] >> @intCast(7 - (d.pos & 7))) & 1 else 0;
        d.pos += 1;
        return b;
    }

    /// 9.3.4.3.2
    pub fn decision(d: *Decoder, ctx: *u8) u1 {
        const state = ctx.* >> 1;
        var mps: u1 = @truncate(ctx.*);
        const lps: u32 = tables.range_lps[state][(d.range >> 6) & 3];
        d.range -= lps;
        var bin: u1 = undefined;
        if (d.offset >= d.range) {
            bin = ~mps;
            d.offset -= d.range;
            d.range = lps;
            if (state == 0) mps = ~mps;
            ctx.* = (tables.trans_lps[state] << 1) | @as(u8, mps);
        } else {
            bin = mps;
            ctx.* = (@as(u8, @min(state + 1, 62)) << 1) | @as(u8, mps);
        }
        while (d.range < 256) {
            d.range <<= 1;
            d.offset = (d.offset << 1) | d.readBit();
        }
        return bin;
    }

    /// 9.3.4.3.4
    pub fn bypass(d: *Decoder) u1 {
        d.offset = (d.offset << 1) | d.readBit();
        if (d.offset >= d.range) {
            d.offset -= d.range;
            return 1;
        }
        return 0;
    }

    /// `n` bypass bins, most significant first.
    pub fn bypassBits(d: *Decoder, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | d.bypass();
        return v;
    }

    /// 9.3.4.3.5: end_of_slice_segment_flag, end_of_subset_one_bit, pcm_flag.
    pub fn terminate(d: *Decoder) u1 {
        d.range -= 2;
        if (d.offset >= d.range) return 1;
        while (d.range < 256) {
            d.range <<= 1;
            d.offset = (d.offset << 1) | d.readBit();
        }
        return 0;
    }

    /// After a terminate bin of 1: the byte position where the arithmetic
    /// codeword ends (its last bit is a 1, then zero bits to byte alignment).
    /// PCM samples start here.
    pub fn bytePosAfterTerminate(d: *const Decoder) usize {
        // the 9 offset bits read so far end at `pos`; the codeword has one more bit
        return (d.pos + 1 + 7) / 8;
    }
};

test "context init matches the spec formula" {
    const c = Contexts.init(26);
    // initValue 154 (slope 0, offset 64 -> preCtxState 64): pStateIdx 0, valMps 1
    try std.testing.expectEqual(@as(u8, 1), c.transquant_bypass[0]);
    // initValue 139 at QP 26: slope = 8*5-45 = -5, offset = (11<<3)-16 = 72
    // pre = ((-5*26)>>4) + 72 = -9 + 72 = 63 -> valMps 0, pStateIdx 0
    try std.testing.expectEqual(@as(u8, 0), c.split_cu[0]);
}
/// Spec arithmetic encoder (H.265 9.3.4.x encoder side, as in HM), for round-trip tests.
const TestEncoder = struct {
    low: u32 = 0,
    range: u32 = 510,
    outstanding: u32 = 0,
    first: bool = true,
    bits: std.ArrayList(u1) = .empty,
    gpa: std.mem.Allocator,

    fn putBit(e: *TestEncoder, b: u1) !void {
        if (e.first) e.first = false else try e.bits.append(e.gpa, b);
        while (e.outstanding > 0) : (e.outstanding -= 1) try e.bits.append(e.gpa, ~b);
    }
    fn renorm(e: *TestEncoder) !void {
        while (e.range < 256) {
            if (e.low < 256) {
                try e.putBit(0);
            } else if (e.low >= 512) {
                e.low -= 512;
                try e.putBit(1);
            } else {
                e.low -= 256;
                e.outstanding += 1;
            }
            e.range <<= 1;
            e.low <<= 1;
        }
    }
    fn decision(e: *TestEncoder, ctx: *u8, bin: u1) !void {
        const state = ctx.* >> 1;
        var mps: u1 = @truncate(ctx.*);
        const lps: u32 = tables.range_lps[state][(e.range >> 6) & 3];
        e.range -= lps;
        if (bin != mps) {
            e.low += e.range;
            e.range = lps;
            if (state == 0) mps = ~mps;
            ctx.* = (tables.trans_lps[state] << 1) | @as(u8, mps);
        } else {
            ctx.* = (@as(u8, @min(state + 1, 62)) << 1) | @as(u8, mps);
        }
        try e.renorm();
    }
    fn bypass(e: *TestEncoder, bin: u1) !void {
        e.low <<= 1;
        if (bin == 1) e.low += e.range;
        if (e.low >= 1024) {
            try e.putBit(1);
            e.low -= 1024;
        } else if (e.low < 512) {
            try e.putBit(0);
        } else {
            e.low -= 512;
            e.outstanding += 1;
        }
    }
    fn terminate(e: *TestEncoder, bin: u1) !void {
        e.range -= 2;
        if (bin == 1) {
            e.low += e.range;
            // flush
            e.range = 2;
            try e.renorm();
            try e.putBit(@truncate(e.low >> 9));
            try e.bits.append(e.gpa, @truncate(e.low >> 8));
            try e.bits.append(e.gpa, 1); // rbsp stop bit
        } else {
            try e.renorm();
        }
    }
    fn bytes(e: *TestEncoder) ![]u8 {
        while (e.bits.items.len % 8 != 0) try e.bits.append(e.gpa, 0);
        const out = try e.gpa.alloc(u8, e.bits.items.len / 8 + 4);
        @memset(out, 0);
        for (e.bits.items, 0..) |b, i| out[i / 8] |= @as(u8, b) << @intCast(7 - i % 8);
        return out;
    }
};

test "arithmetic decoder round-trips the spec encoder" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    var prng: std.Random.DefaultPrng = .init(1234);
    const rnd = prng.random();
    const n = 20000;
    const kinds = try gpa.alloc(u8, n);
    const vals = try gpa.alloc(u1, n);
    for (kinds, vals, 0..) |*k, *v, i| {
        k.* = rnd.uintLessThan(u8, 6); // 0..3 contexts, 4 bypass, 5 terminate(0)
        // skewed bins so contexts adapt
        v.* = if (k.* < 4) @intFromBool(rnd.uintLessThan(u8, 10) < 2 + 2 * k.*) else rnd.int(u1);
        if (k.* == 5) v.* = 0;
        if (i == n - 1) {
            k.* = 5;
            v.* = 1;
        }
    }
    var ectx = Contexts.init(22);
    var e: TestEncoder = .{ .gpa = gpa };
    const ep: [*]u8 = @ptrCast(&ectx);
    for (kinds, vals) |k, v| switch (k) {
        0...3 => try e.decision(&ep[k * 7], v),
        4 => try e.bypass(v),
        else => try e.terminate(v),
    };
    const data = try e.bytes();
    var dctx = Contexts.init(22);
    const dp: [*]u8 = @ptrCast(&dctx);
    var d: Decoder = .init(data, 0);
    for (kinds, vals) |k, v| {
        const got: u1 = switch (k) {
            0...3 => d.decision(&dp[k * 7]),
            4 => d.bypass(),
            else => d.terminate(),
        };
        try std.testing.expectEqual(v, got);
    }
}

test "an MPS moves high states up too" {
    // regression: @min(state + 1, 62) is a u6, so `<< 1` dropped the top bit for states >= 32
    var ctx: u8 = (40 << 1) | 1;
    const zeros: [8]u8 = @splat(0);
    var d: Decoder = .init(&zeros, 0);
    try std.testing.expectEqual(@as(u1, 1), d.decision(&ctx));
    try std.testing.expectEqual(@as(u8, (41 << 1) | 1), ctx);
}
