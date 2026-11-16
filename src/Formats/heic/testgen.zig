//! Test data for the HEIC decoder, generated here: small, valid HEVC still
//! pictures (H.265 Main, intra only) and HEIF files around them. The tests
//! use these instead of third-party sample files.
//!
//! This is not a real encoder. Each coding unit is either PCM (the source
//! samples, verbatim) or intra predicted (any mode) with at most one luma DC
//! coefficient. That drives the parameter-set and slice-header parsers, CABAC
//! (context-coded, bypass and terminate bins, and the restart after PCM), the
//! coding quadtree (including the implicit split at the picture edge), the
//! most-probable-mode coding, intra prediction, residual coding,
//! dequantization and the inverse DCT, and availability across slices, with
//! results that can be worked out by hand (`sample`). The in-loop filters
//! are off: the PPS disables deblocking and the SPS disables SAO.
//!
//! Everything is allocated in `gpa` and never freed one by one: pass an arena.
const std = @import("std");
const Allocator = std.mem.Allocator;
const cabac = @import("hevc/cabac.zig");

// ───────────────────────────── Bits and NAL units ─────────────────────────────

/// RBSP writer: MSB-first bits and the Exp-Golomb codes (H.265 9.2).
pub const BitWriter = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    n: usize = 0,

    pub fn bit(w: *BitWriter, b: u1) !void {
        if (w.n % 8 == 0) try w.out.append(w.gpa, 0);
        if (b == 1) w.out.items[w.n / 8] |= @as(u8, 0x80) >> @intCast(w.n % 8);
        w.n += 1;
    }
    pub fn bits(w: *BitWriter, v: u64, n: u7) !void {
        var i = n;
        while (i > 0) {
            i -= 1;
            try w.bit(@truncate(v >> @intCast(i)));
        }
    }
    pub fn flag(w: *BitWriter, b: bool) !void {
        try w.bit(@intFromBool(b));
    }
    /// ue(v)
    pub fn ue(w: *BitWriter, v: u32) !void {
        const x: u64 = @as(u64, v) + 1;
        const len: u7 = 64 - @as(u7, @clz(x));
        try w.bits(0, len - 1);
        try w.bits(x, len);
    }
    /// se(v): 1 -> 1, -1 -> 2, 2 -> 3, ...
    pub fn se(w: *BitWriter, v: i32) !void {
        try w.ue(if (v > 0) @intCast(2 * v - 1) else @intCast(-2 * v));
    }
    /// rbsp_trailing_bits() / byte_alignment(): a 1, then zeros to the byte boundary.
    pub fn trailing(w: *BitWriter) !void {
        try w.bit(1);
        while (w.n % 8 != 0) try w.bit(0);
    }
};

/// A NAL unit: the 2-byte header (layer 0, TemporalId 0), then the rbsp with
/// emulation prevention bytes (7.4.2).
pub fn nal(gpa: Allocator, nal_type: u6, rbsp: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(gpa, &.{ @as(u8, nal_type) << 1, 1 });
    var zeros: usize = 0;
    for (rbsp) |b| {
        if (zeros >= 2 and b <= 3) {
            try out.append(gpa, 3);
            zeros = 0;
        }
        try out.append(gpa, b);
        zeros = if (b == 0) zeros + 1 else 0;
    }
    return out.items;
}

// ───────────────────────────── Pictures ─────────────────────────────

pub const ChromaMode = enum(u3) { planar = 0, vertical = 1, horizontal = 2, dc = 3, dm = 4 };

pub const Intra = struct {
    /// luma: 0 planar, 1 DC, 2..34 angular (10 horizontal, 26 vertical)
    mode: u8 = 1,
    /// intra_chroma_pred_mode; `dm` takes the luma mode
    chroma: ChromaMode = .dm,
    /// level of the one luma DC coefficient (0: no residual)
    dc: i32 = 0,
};

/// One coding tree.
pub const Cu = union(enum) {
    /// a PCM coding unit holding the source samples
    pcm,
    intra: Intra,
    /// four quadrants in z order; those outside the picture are not coded
    split: *const [4]Cu,
};

pub const Picture = struct {
    width: u32,
    height: u32,
    /// 0 monochrome, 1 4:2:0
    chroma_format: u2 = 1,
    /// 4 (16x16) or 5 (32x32); coding units are 8x8 at least
    log2_ctb: u3 = 4,
    qp: i32 = 26,
    /// VUI colour description (H.273)
    full_range: bool = true,
    matrix: u8 = 1,
    /// conformance window in luma samples (left, right, top, bottom); even for 4:2:0
    crop: [4]u32 = @splat(0),
    /// one coding tree per CTU, in raster order
    ctus: []const Cu,
    /// first CTU of each independent slice segment, ascending, starting with 0
    slices: []const u32 = &.{0},
    /// 8-bit source samples for the PCM coding units (Cb / Cr empty for monochrome)
    y: []const u8,
    cb: []const u8 = &.{},
    cr: []const u8 = &.{},
};

pub const Stream = struct {
    /// VPS, SPS and PPS NAL units
    param_sets: []const []const u8,
    /// slice segment NAL units
    slices: []const []const u8,

    /// The slices with 4-byte big-endian length prefixes (HEIF item data).
    pub fn lengthPrefixed(s: Stream, gpa: Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s.slices) |n| {
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, @intCast(n.len), .big);
            try out.appendSlice(gpa, &len);
            try out.appendSlice(gpa, n);
        }
        return out.items;
    }
};

const log2_min_cb = 3;
const level_idc = 60; // level 2

pub fn encode(gpa: Allocator, p: Picture) !Stream {
    if (p.width % 8 != 0 or p.height % 8 != 0) return error.SizeNotMultipleOf8;
    const max_tb: u3 = @min(p.log2_ctb, 5);
    const sets = try gpa.alloc([]const u8, 3);
    sets[0] = try vps(gpa);
    sets[1] = try sps(gpa, p, max_tb);
    sets[2] = try pps(gpa);

    const w_ctbs = (p.width + (@as(u32, 1) << p.log2_ctb) - 1) >> p.log2_ctb;
    const n_ctbs = w_ctbs * ((p.height + (@as(u32, 1) << p.log2_ctb) - 1) >> p.log2_ctb);
    if (p.ctus.len != n_ctbs or p.slices.len == 0 or p.slices[0] != 0) return error.BadLayout;

    const w4 = p.width / 4;
    const n4 = w4 * (p.height / 4);
    var e: Encoder = .{
        .p = &p,
        .max_tb = max_tb,
        .w4 = w4,
        .depth = try gpa.alloc(u8, n4),
        .mode = try gpa.alloc(u8, n4),
        .slice = try gpa.alloc(u16, n4),
        .decoded = try gpa.alloc(bool, n4),
        .e = .{ .gpa = gpa },
    };
    @memset(e.decoded, false);

    const slices = try gpa.alloc([]const u8, p.slices.len);
    for (p.slices, 0..) |start, k| {
        const end = if (k + 1 < p.slices.len) p.slices[k + 1] else n_ctbs;
        if (end <= start) return error.BadLayout;
        var w: BitWriter = .{ .gpa = gpa };
        // slice segment header (7.3.6.1) of an IDR picture with an I slice
        try w.flag(start == 0); // first_slice_segment_in_pic_flag
        try w.bit(0); // no_output_of_prior_pics_flag
        try w.ue(0); // slice_pic_parameter_set_id
        if (start != 0) try w.bits(start, std.math.log2_int_ceil(u32, n_ctbs)); // slice_segment_address
        try w.ue(2); // slice_type I
        try w.se(p.qp - 26); // slice_qp_delta (init_qp is 26)
        try w.trailing(); // byte_alignment()

        e.cur_slice = @intCast(k);
        e.ctx = .init(p.qp);
        e.e = .{ .gpa = gpa };
        for (start..end) |rs| {
            const x: u32 = @intCast((rs % w_ctbs) << p.log2_ctb);
            const y: u32 = @intCast((rs / w_ctbs) << p.log2_ctb);
            e.fill(u16, e.slice, x, y, @as(u32, 1) << p.log2_ctb, e.cur_slice);
            try e.quadtree(x, y, p.log2_ctb, 0, p.ctus[rs]);
            try e.e.terminate(@intFromBool(rs + 1 == end)); // end_of_slice_segment_flag
        }
        try e.e.alignZero(); // after the stop bit
        for (e.e.bits.items) |b| try w.bit(b);
        slices[k] = try nal(gpa, 19, w.out.items); // IDR_W_RADL
    }
    return .{ .param_sets = sets, .slices = slices };
}

/// general_profile_tier_level for Main, level 2 (7.3.3).
fn profileTierLevel(w: *BitWriter) !void {
    try w.bits(0, 2); // profile space
    try w.bit(0); // tier
    try w.bits(1, 5); // profile_idc: Main
    try w.bits(0x6000_0000, 32); // compatible with Main and Main 10
    try w.bits(0b1001, 4); // progressive, not interlaced, no packing constraint, frame only
    try w.bits(0, 43);
    try w.bit(0);
    try w.bits(level_idc, 8);
}

fn vps(gpa: Allocator) ![]u8 {
    var w: BitWriter = .{ .gpa = gpa };
    try w.bits(0, 4); // vps_video_parameter_set_id
    try w.bits(0b11, 2); // base layer internal and available
    try w.bits(0, 6); // max layers - 1
    try w.bits(0, 3); // max sub-layers - 1
    try w.bit(1); // temporal id nesting
    try w.bits(0xFFFF, 16);
    try profileTierLevel(&w);
    try w.bit(1); // sub-layer ordering info present
    for (0..3) |_| try w.ue(0); // max dec pic buffering - 1, num reorder, max latency increase
    try w.bits(0, 6); // vps_max_layer_id
    try w.ue(0); // num layer sets - 1
    try w.bit(0); // no timing info
    try w.bit(0); // no extension
    try w.trailing();
    return nal(gpa, 32, w.out.items);
}

fn sps(gpa: Allocator, p: Picture, max_tb: u3) ![]u8 {
    var w: BitWriter = .{ .gpa = gpa };
    try w.bits(0, 4); // vps id
    try w.bits(0, 3); // max sub-layers - 1
    try w.bit(1); // temporal id nesting
    try profileTierLevel(&w);
    try w.ue(0); // sps id
    try w.ue(p.chroma_format);
    try w.ue(p.width);
    try w.ue(p.height);
    const cropped = !std.mem.allEqual(u32, &p.crop, 0);
    try w.flag(cropped); // conformance window, in chroma sample units
    if (cropped) {
        const sub: u32 = if (p.chroma_format == 1) 2 else 1;
        for (p.crop) |c| {
            if (c % sub != 0) return error.OddCrop;
            try w.ue(c / sub);
        }
    }
    try w.ue(0); // bit depth luma - 8
    try w.ue(0); // bit depth chroma - 8
    try w.ue(0); // log2_max_pic_order_cnt_lsb - 4
    try w.bit(1); // sub-layer ordering info present
    for (0..3) |_| try w.ue(0);
    try w.ue(log2_min_cb - 3);
    try w.ue(p.log2_ctb - log2_min_cb);
    try w.ue(0); // log2_min_tb - 2
    try w.ue(max_tb - 2); // log2 diff max min tb
    try w.ue(0); // max transform hierarchy depth inter
    try w.ue(0); // ... intra: one transform unit per coding unit
    try w.bit(0); // scaling lists off
    try w.bit(0); // amp
    try w.bit(0); // sao off
    try w.bit(1); // pcm on
    try w.bits(7, 4); // pcm luma bit depth - 1
    try w.bits(7, 4); // pcm chroma bit depth - 1
    try w.ue(0); // log2 min pcm - 3: 8x8
    try w.ue(@min(p.log2_ctb, 5) - 3); // log2 diff max min pcm: up to the CTB
    try w.bit(1); // pcm_loop_filter_disabled
    try w.ue(0); // no short-term reference picture sets
    try w.bit(0); // no long-term references
    try w.bit(0); // temporal mvp
    try w.bit(0); // strong intra smoothing
    try w.bit(1); // vui present (E.2.1)
    try w.bit(0); // aspect ratio
    try w.bit(0); // overscan
    try w.bit(1); // video signal type
    try w.bits(5, 3); // video format: unspecified
    try w.flag(p.full_range);
    try w.bit(1); // colour description
    try w.bits(1, 8); // primaries BT.709
    try w.bits(13, 8); // transfer sRGB
    try w.bits(p.matrix, 8);
    try w.bit(0); // chroma location
    try w.bit(0); // neutral chroma
    try w.bit(0); // field seq
    try w.bit(0); // frame field info
    try w.bit(0); // default display window
    try w.bit(0); // timing info
    try w.bit(0); // bitstream restriction
    try w.bit(0); // no sps extension
    try w.trailing();
    return nal(gpa, 33, w.out.items);
}

fn pps(gpa: Allocator) ![]u8 {
    var w: BitWriter = .{ .gpa = gpa };
    try w.ue(0); // pps id
    try w.ue(0); // sps id
    try w.bit(0); // dependent slices
    try w.bit(0); // output flag present
    try w.bits(0, 3); // extra slice header bits
    try w.bit(0); // sign data hiding
    try w.bit(0); // cabac init present
    try w.ue(0); // num ref idx l0 default - 1
    try w.ue(0); // l1
    try w.se(0); // init qp - 26
    try w.bit(0); // constrained intra pred
    try w.bit(0); // transform skip
    try w.bit(0); // cu qp delta
    try w.se(0); // cb qp offset
    try w.se(0); // cr qp offset
    try w.bit(0); // slice chroma qp offsets present
    try w.bit(0); // weighted pred
    try w.bit(0); // weighted bipred
    try w.bit(0); // transquant bypass
    try w.bit(0); // tiles
    try w.bit(0); // entropy coding sync
    try w.bit(0); // loop filter across slices
    try w.bit(1); // deblocking filter control present
    try w.bit(0); // override enabled
    try w.bit(1); // pps_deblocking_filter_disabled_flag
    try w.bit(0); // scaling list data
    try w.bit(0); // lists modification
    try w.ue(0); // log2 parallel merge level - 2
    try w.bit(0); // slice header extension
    try w.bit(0); // pps extension
    try w.trailing();
    return nal(gpa, 34, w.out.items);
}

const Encoder = struct {
    p: *const Picture,
    max_tb: u3,
    /// per 4x4 luma block
    w4: usize,
    depth: []u8,
    mode: []u8,
    slice: []u16,
    decoded: []bool,
    cur_slice: u16 = 0,
    ctx: cabac.Contexts = undefined,
    e: cabac.TestEncoder,

    fn at(s: *const Encoder, x: usize, y: usize) usize {
        return (y >> 2) * s.w4 + (x >> 2);
    }

    fn fill(s: *Encoder, comptime T: type, map: []T, x0: usize, y0: usize, size: usize, v: T) void {
        var y = y0;
        while (y < @min(y0 + size, s.p.height)) : (y += 4) {
            var x = x0;
            while (x < @min(x0 + size, s.p.width)) : (x += 4) map[s.at(x, y)] = v;
        }
    }

    /// 6.4.1 with one tile: inside the picture, already coded, in the same slice.
    fn available(s: *const Encoder, x: usize, y: usize) bool {
        if (x >= s.p.width or y >= s.p.height) return false;
        const i = s.at(x, y);
        return s.decoded[i] and s.slice[i] == s.cur_slice;
    }
    fn leftOk(s: *const Encoder, x: usize, y: usize) bool {
        return x > 0 and s.available(x - 1, y);
    }
    fn aboveOk(s: *const Encoder, x: usize, y: usize) bool {
        return y > 0 and s.available(x, y - 1);
    }

    /// 7.3.8.4 coding_quadtree
    fn quadtree(s: *Encoder, x0: u32, y0: u32, log2: u3, depth: u8, cu: Cu) !void {
        const size = @as(u32, 1) << log2;
        const split = cu == .split;
        if (x0 + size <= s.p.width and y0 + size <= s.p.height and log2 > log2_min_cb) {
            var inc: usize = 0;
            if (s.leftOk(x0, y0) and s.depth[s.at(x0 - 1, y0)] > depth) inc += 1;
            if (s.aboveOk(x0, y0) and s.depth[s.at(x0, y0 - 1)] > depth) inc += 1;
            try s.e.decision(&s.ctx.split_cu[inc], @intFromBool(split)); // split_cu_flag
        } else if (log2 > log2_min_cb) {
            if (!split) return error.MustSplitAtPictureEdge;
        } else if (split) return error.CodingUnitTooSmall;
        if (split) {
            const half = size / 2;
            for (cu.split, [_][2]u32{ .{ 0, 0 }, .{ half, 0 }, .{ 0, half }, .{ half, half } }) |child, o| {
                if (x0 + o[0] < s.p.width and y0 + o[1] < s.p.height) try s.quadtree(x0 + o[0], y0 + o[1], log2 - 1, depth + 1, child);
            }
            return;
        }
        try s.codingUnit(x0, y0, log2, depth, cu);
    }

    /// 7.3.8.5 coding_unit (2Nx2N, intra)
    fn codingUnit(s: *Encoder, x0: u32, y0: u32, log2: u3, depth: u8, cu: Cu) !void {
        const size = @as(u32, 1) << log2;
        s.fill(u8, s.depth, x0, y0, size, depth);
        if (log2 == log2_min_cb) try s.e.decision(&s.ctx.part_mode[0], 1); // PART_2Nx2N
        if (log2 <= @min(s.p.log2_ctb, 5)) {
            try s.e.terminate(@intFromBool(cu == .pcm)); // pcm_flag
        } else if (cu == .pcm) return error.PcmTooLarge;

        switch (cu) {
            .pcm => {
                try s.e.alignZero(); // pcm_alignment_zero_bits
                try s.pcmPlane(s.p.y, s.p.width, x0, y0, size);
                if (s.p.chroma_format != 0) {
                    try s.pcmPlane(s.p.cb, s.p.width / 2, x0 / 2, y0 / 2, size / 2);
                    try s.pcmPlane(s.p.cr, s.p.width / 2, x0 / 2, y0 / 2, size / 2);
                }
                s.e.restart(); // 9.3.2.5
                s.fill(u8, s.mode, x0, y0, size, 1); // PCM counts as DC for later MPMs
            },
            .intra => |m| {
                if (log2 > s.max_tb) return error.TransformTooLarge;
                try s.lumaMode(x0, y0, m.mode);
                s.fill(u8, s.mode, x0, y0, size, m.mode);
                if (s.p.chroma_format != 0) {
                    // intra_chroma_pred_mode: 0 -> DM, else 1 and two bypass bins
                    if (m.chroma == .dm) {
                        try s.e.decision(&s.ctx.intra_chroma_pred_mode[0], 0);
                    } else {
                        try s.e.decision(&s.ctx.intra_chroma_pred_mode[0], 1);
                        try s.bypassBits(@backingInt(m.chroma), 2);
                    }
                }
                // transform_tree at depth 0: one transform unit, split_transform_flag not coded
                if (s.p.chroma_format != 0) {
                    try s.e.decision(&s.ctx.cbf_chroma[0], 0); // cbf_cb
                    try s.e.decision(&s.ctx.cbf_chroma[0], 0); // cbf_cr
                }
                try s.e.decision(&s.ctx.cbf_luma[1], @intFromBool(m.dc != 0));
                if (m.dc != 0) try s.dcResidual(log2, m.dc);
            },
            .split => unreachable,
        }
        s.fill(bool, s.decoded, x0, y0, size, true);
    }

    fn pcmPlane(s: *Encoder, plane: []const u8, stride: usize, x0: usize, y0: usize, n: usize) !void {
        for (0..n) |y| for (0..n) |x| try s.e.raw(plane[(y0 + y) * stride + x0 + x], 8);
    }

    fn bypassBits(s: *Encoder, v: u32, n: u5) !void {
        var i = n;
        while (i > 0) {
            i -= 1;
            try s.e.bypass(@truncate(v >> i));
        }
    }

    /// 8.4.2: prev_intra_luma_pred_flag + mpm_idx, or rem_intra_luma_pred_mode.
    fn lumaMode(s: *Encoder, x0: u32, y0: u32, mode: u8) !void {
        const dc = 1;
        const a: u8 = if (s.leftOk(x0, y0)) s.mode[s.at(x0 - 1, y0)] else dc;
        const ctb_top = (y0 >> s.p.log2_ctb) << s.p.log2_ctb;
        const b: u8 = if (y0 == ctb_top or !s.aboveOk(x0, y0)) dc else s.mode[s.at(x0, y0 - 1)];
        var cand: [3]u8 = undefined;
        if (a == b) {
            cand = if (a < 2) .{ 0, 1, 26 } else .{ a, 2 + ((a + 29) % 32), 2 + ((a - 2 + 1) % 32) };
        } else {
            cand = .{ a, b, if (a != 0 and b != 0) 0 else if (a != 1 and b != 1) 1 else 26 };
        }
        if (std.mem.indexOfScalar(u8, &cand, mode)) |i| {
            try s.e.decision(&s.ctx.prev_intra_luma_pred[0], 1);
            // mpm_idx, truncated rice: 0, 10, 11
            try s.e.bypass(@intFromBool(i > 0));
            if (i > 0) try s.e.bypass(@intFromBool(i > 1));
        } else {
            try s.e.decision(&s.ctx.prev_intra_luma_pred[0], 0);
            var rem = mode;
            for (cand) |c| {
                if (mode > c) rem -= 1;
            }
            try s.bypassBits(rem, 5);
        }
    }

    /// 7.3.8.11 residual_coding of a luma block whose only coefficient is the DC one.
    fn dcResidual(s: *Encoder, log2: u3, level: i32) !void {
        const offset = 3 * (@as(usize, log2) - 2) + ((@as(usize, log2) - 1) >> 2);
        try s.e.decision(&s.ctx.last_x_prefix[offset], 0); // last_sig_coeff_x_prefix 0
        try s.e.decision(&s.ctx.last_y_prefix[offset], 0); // last_sig_coeff_y_prefix 0
        const abs: u32 = @abs(level);
        // ctxSet 0, greater1Ctx 1
        try s.e.decision(&s.ctx.greater1[1], @intFromBool(abs > 1));
        if (abs > 1) try s.e.decision(&s.ctx.greater2[0], @intFromBool(abs > 2));
        try s.e.bypass(@intFromBool(level < 0)); // sign (no sign hiding)
        if (abs > 2) try s.remaining(abs - 3, 0);
    }

    /// 9.3.3.11 coeff_abs_level_remaining: Rice prefix, Exp-Golomb escape.
    fn remaining(s: *Encoder, v: u32, rice: u5) !void {
        if (v < (@as(u32, 4) << rice)) {
            const prefix = v >> rice;
            for (0..prefix) |_| try s.e.bypass(1);
            try s.e.bypass(0);
            try s.bypassBits(v, rice);
            return;
        }
        const base = struct {
            fn f(p: u32, k: u5) u32 {
                return ((@as(u32, 1) << @intCast(p - 3)) + 2) << k;
            }
        }.f;
        var p: u32 = 4;
        while (v >= base(p + 1, rice)) p += 1;
        for (0..p) |_| try s.e.bypass(1);
        try s.e.bypass(0);
        try s.bypassBits(v - base(p, rice), @intCast(p - 3 + rice));
    }
};

// ───────────────────────────── Test pictures ─────────────────────────────

/// Seeded test content: a luma ramp with noise and, unless `gray`, chroma
/// ramps with noise (gray chroma is 128, so RGB equals luma at full range).
pub fn source(gpa: Allocator, w: u32, h: u32, chroma_format: u2, gray: bool, seed: u64) ![3][]u8 {
    var prng: std.Random.DefaultPrng = .init(seed);
    const rnd = prng.random();
    var out: [3][]u8 = .{ try gpa.alloc(u8, @as(usize, w) * h), &.{}, &.{} };
    for (0..h) |y| for (0..w) |x| {
        out[0][y * w + x] = @truncate(x * 3 + y * 5 + 16 + rnd.uintLessThan(usize, 24));
    };
    if (chroma_format == 0) return out;
    const cw = w / 2;
    const ch = h / 2;
    for (1..3) |c| {
        out[c] = try gpa.alloc(u8, @as(usize, cw) * ch);
        for (0..ch) |y| for (0..cw) |x| {
            out[c][y * cw + x] = if (gray) 128 else @truncate(if (c == 1) 40 + x * 6 + rnd.uintLessThan(usize, 16) else 220 - y * 5 - rnd.uintLessThan(usize, 16));
        };
    }
    return out;
}

/// The residual a lone DC coefficient adds to every sample of an nTbS x nTbS
/// luma block, 8-bit, flat scaling (8.6.2 scaling, 8.6.4.2 two DCT stages:
/// every DCT basis function's first coefficient is 64).
pub fn dcResidual(level: i32, log2: u3, qp: i32) i32 {
    const level_scale = [6]i32{ 40, 45, 51, 57, 64, 72 };
    const bd_shift: u5 = @intCast(8 + @as(i32, log2) - 5);
    const d = (level * 16 * (level_scale[@intCast(@mod(qp, 6))] << @intCast(@divFloor(qp, 6))) + (@as(i32, 1) << (bd_shift - 1))) >> bd_shift;
    const e = std.math.clamp((64 * d + 64) >> 7, -32768, 32767);
    return (64 * e + (1 << 11)) >> 12;
}

pub const Sample = struct {
    picture: Picture,
    /// the decoded Y, Cb, Cr planes, worked out by hand
    expected: [3][]u8,
};

const dc_level = 20;

/// A 48x32 4:2:0 picture of 3x2 CTUs (16x16), with the decoded result:
///
///     CTU 0: DC, no neighbours, one DC coefficient  CTU 1: PCM 16x16   CTU 2: four PCM 8x8
///     CTU 3: DC from CTU 0, chroma "vertical"       CTU 4: vertical    CTU 5: horizontal
///
/// With `two_slices` a second slice starts at CTU 3, so row 1 can't see row 0:
/// CTU 3 predicts from nothing, CTU 4 is PCM and CTU 5 predicts from CTU 4 only.
pub fn sample(gpa: Allocator, two_slices: bool, gray: bool) !Sample {
    const w = 48;
    const h = 32;
    const src = try source(gpa, w, h, 1, gray, if (two_slices) 0x4845_4943 else 0x4845_5643);
    const pcm8 = try gpa.create([4]Cu);
    pcm8.* = @splat(.pcm);
    const ctus = try gpa.dupe(Cu, &.{
        .{ .intra = .{ .mode = 1, .dc = dc_level } },
        .pcm,
        .{ .split = pcm8 },
        .{ .intra = .{ .mode = 1, .chroma = .vertical } },
        if (two_slices) .pcm else .{ .intra = .{ .mode = 26 } },
        .{ .intra = .{ .mode = 10 } },
    });
    const pic: Picture = .{
        .width = w,
        .height = h,
        .ctus = ctus,
        .slices = if (two_slices) &.{ 0, 3 } else &.{0},
        .y = src[0],
        .cb = src[1],
        .cr = src[2],
    };

    const Y = src[0];
    const C = [2][]const u8{ src[1], src[2] };
    const exp: [3][]u8 = .{ try gpa.dupe(u8, Y), try gpa.dupe(u8, C[0]), try gpa.dupe(u8, C[1]) };
    const cw = w / 2;
    const flat0: u8 = @intCast(128 + dcResidual(dc_level, 4, pic.qp));
    for (0..16) |y| for (0..16) |x| {
        // CTU 0: nothing to predict from (all references 128), plus the DC residual
        exp[0][y * w + x] = flat0;
        // CTU 3: DC of CTU 0's flat bottom row and its substituted left column
        // (the DC edge filter keeps a flat block flat); with two slices CTU 0
        // isn't available: 128
        exp[0][(16 + y) * w + x] = if (two_slices) 128 else flat0;
        if (!two_slices) {
            // CTU 4, vertical: each column repeats CTU 1's bottom row. The
            // column-0 edge filter adds (left - corner) / 2 = 0: both are flat0.
            exp[0][(16 + y) * w + 16 + x] = Y[15 * w + 16 + x];
            // CTU 5, horizontal: each row repeats CTU 4's right column, which is
            // A = Y(31, 15); row 0's edge filter adds (above - corner) >> 1 with
            // the corner A too
            const a: i32 = Y[15 * w + 31];
            exp[0][(16 + y) * w + 32 + x] = if (y == 0)
                @intCast(std.math.clamp(a + ((@as(i32, Y[15 * w + 32 + x]) - a) >> 1), 0, 255))
            else
                @intCast(a);
        } else {
            // CTU 5, horizontal from CTU 4 (PCM) only; the unavailable corner and
            // above row are substituted with the left column's top sample, so
            // the row-0 edge filter adds nothing
            exp[0][(16 + y) * w + 32 + x] = Y[(16 + y) * w + 31];
        }
    };
    for (0..2) |c| for (0..8) |y| for (0..8) |x| {
        exp[1 + c][y * cw + x] = 128; // CTU 0
        exp[1 + c][(8 + y) * cw + x] = 128; // CTU 3: vertical from CTU 0 (or nothing)
        if (!two_slices) {
            // chroma uses the luma mode (DM) and has no edge filters
            exp[1 + c][(8 + y) * cw + 8 + x] = C[c][7 * cw + 8 + x]; // vertical
            exp[1 + c][(8 + y) * cw + 16 + x] = C[c][7 * cw + 15]; // horizontal from CTU 4's right column
        } else {
            exp[1 + c][(8 + y) * cw + 16 + x] = C[c][(8 + y) * cw + 15];
        }
    };
    return .{ .picture = pic, .expected = exp };
}

/// A monochrome picture of PCM coding units only (an alpha plane). Heights
/// that aren't a multiple of 16 end in CTUs split at the picture edge.
pub fn pcmPicture(gpa: Allocator, w: u32, h: u32, seed: u64) !Picture {
    const src = try source(gpa, w, h, 0, true, seed);
    const pcm8 = try gpa.create([4]Cu);
    pcm8.* = @splat(.pcm);
    const w_ctbs = (w + 15) / 16;
    const h_ctbs = (h + 15) / 16;
    const ctus = try gpa.alloc(Cu, w_ctbs * h_ctbs);
    for (ctus, 0..) |*c, i| {
        const edge = (i % w_ctbs + 1) * 16 > w or (i / w_ctbs + 1) * 16 > h;
        c.* = if (edge) .{ .split = pcm8 } else .pcm;
    }
    return .{ .width = w, .height = h, .chroma_format = 0, .ctus = ctus, .y = src[0] };
}

// ───────────────────────────── HEIF ─────────────────────────────

/// An ISO BMFF box holding `parts`, concatenated.
pub fn box(gpa: Allocator, box_type: *const [4]u8, parts: []const []const u8) ![]u8 {
    var size: usize = 8;
    for (parts) |p| size += p.len;
    var out: std.ArrayList(u8) = try .initCapacity(gpa, size);
    out.appendSliceAssumeCapacity(&be(u32, @intCast(size)));
    out.appendSliceAssumeCapacity(box_type);
    for (parts) |p| out.appendSliceAssumeCapacity(p);
    return out.items;
}

fn be(comptime T: type, v: T) [@sizeOf(T)]u8 {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .big);
    return b;
}

/// version + flags of a FullBox
fn full(version: u8, flags: u24) [4]u8 {
    return be(u32, (@as(u32, version) << 24) | flags);
}

/// HEVCDecoderConfigurationRecord (ISO/IEC 14496-15 8.3.3.1) for `encode`'s streams.
pub fn hvcC(gpa: Allocator, s: Stream, chroma_format: u2) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(gpa, &.{ 1, 0x01 }); // version; profile space, tier, Main
    try body.appendSlice(gpa, &be(u32, 0x6000_0000));
    try body.appendSlice(gpa, &.{ 0x90, 0, 0, 0, 0, 0, level_idc });
    try body.appendSlice(gpa, &.{ 0xF0, 0x00, 0xFC, 0xFC | @as(u8, chroma_format), 0xF8, 0xF8, 0, 0 });
    try body.append(gpa, 0x0F); // one temporal layer, nested, 4-byte NAL lengths
    try body.append(gpa, @intCast(s.param_sets.len));
    for (s.param_sets) |ps| {
        try body.append(gpa, 0x80 | (ps[0] >> 1)); // complete; NAL unit type
        try body.appendSlice(gpa, &be(u16, 1));
        try body.appendSlice(gpa, &be(u16, @intCast(ps.len)));
        try body.appendSlice(gpa, ps);
    }
    return box(gpa, "hvcC", &.{body.items});
}

pub fn ispe(gpa: Allocator, w: u32, h: u32) ![]u8 {
    return box(gpa, "ispe", &.{ &full(0, 0), &be(u32, w), &be(u32, h) });
}

/// Counter-clockwise quarter turns.
pub fn irot(gpa: Allocator, turns: u2) ![]u8 {
    return box(gpa, "irot", &.{&[1]u8{turns}});
}

/// A centred clean aperture of w x h (integer sizes, no offset).
pub fn clap(gpa: Allocator, w: u32, h: u32) ![]u8 {
    return box(gpa, "clap", &.{ &be(u32, w), &be(u32, 1), &be(u32, h), &be(u32, 1), &be(u32, 0), &be(u32, 1), &be(u32, 0), &be(u32, 1) });
}

pub fn colrNclx(gpa: Allocator, primaries: u16, transfer: u16, matrix: u16, full_range: bool) ![]u8 {
    return box(gpa, "colr", &.{ "nclx", &be(u16, primaries), &be(u16, transfer), &be(u16, matrix), &[1]u8{if (full_range) 0x80 else 0} });
}

pub fn auxCAlpha(gpa: Allocator) ![]u8 {
    return box(gpa, "auxC", &.{ &full(0, 0), "urn:mpeg:hevc:2015:auxid:1\x00" });
}

/// The bytes of a `grid` item (ISO/IEC 23008-12 6.6.2.3).
pub fn gridData(rows: u8, columns: u8, w: u16, h: u16) [8]u8 {
    var d: [8]u8 = .{ 0, 0, rows - 1, columns - 1, 0, 0, 0, 0 }; // version, flags (16-bit sizes)
    std.mem.writeInt(u16, d[4..6], w, .big);
    std.mem.writeInt(u16, d[6..8], h, .big);
    return d;
}

pub const Item = struct {
    id: u16,
    type: *const [4]u8,
    data: []const u8,
    /// 1-based indices into the property list
    props: []const u8 = &.{},
};

pub const Ref = struct { type: *const [4]u8, from: u16, to: []const u16 };

/// A HEIF file: ftyp, meta (hdlr, pitm, iinf, iloc, iref, iprp) and one mdat
/// holding every item's data.
pub fn heif(gpa: Allocator, primary: u16, items: []const Item, refs: []const Ref, props: []const []const u8) ![]u8 {
    const ftyp = try box(gpa, "ftyp", &.{ "heic", &be(u32, 0), "mif1", "heic" });
    // iloc holds file offsets into the mdat, which follows meta: size meta first
    const probe = try meta(gpa, primary, items, refs, props, 0);
    const meta_box = try meta(gpa, primary, items, refs, props, ftyp.len + probe.len + 8);
    var parts: std.ArrayList([]const u8) = .empty;
    for (items) |it| try parts.append(gpa, it.data);
    const mdat = try box(gpa, "mdat", parts.items);
    return std.mem.concat(gpa, u8, &.{ ftyp, meta_box, mdat });
}

fn meta(gpa: Allocator, primary: u16, items: []const Item, refs: []const Ref, props: []const []const u8, data_start: usize) ![]u8 {
    const hdlr = try box(gpa, "hdlr", &.{ &full(0, 0), &be(u32, 0), "pict", &@as([12]u8, @splat(0)), "\x00" });
    const pitm = try box(gpa, "pitm", &.{ &full(0, 0), &be(u16, primary) });

    var infe: std.ArrayList([]const u8) = .empty;
    try infe.appendSlice(gpa, &.{ &full(0, 0), &be(u16, @intCast(items.len)) });
    for (items) |it| try infe.append(gpa, try box(gpa, "infe", &.{ &full(2, 0), &be(u16, it.id), &be(u16, 0), it.type, "\x00" }));
    const iinf = try box(gpa, "iinf", infe.items);

    var loc: std.ArrayList(u8) = .empty;
    try loc.appendSlice(gpa, &full(0, 0));
    try loc.appendSlice(gpa, &be(u16, 0x4400)); // 4-byte offsets and lengths, no base offset
    try loc.appendSlice(gpa, &be(u16, @intCast(items.len)));
    var offset = data_start;
    for (items) |it| {
        try loc.appendSlice(gpa, &be(u16, it.id));
        try loc.appendSlice(gpa, &be(u16, 0)); // this file
        try loc.appendSlice(gpa, &be(u16, 1)); // one extent
        try loc.appendSlice(gpa, &be(u32, @intCast(offset)));
        try loc.appendSlice(gpa, &be(u32, @intCast(it.data.len)));
        offset += it.data.len;
    }
    const iloc = try box(gpa, "iloc", &.{loc.items});

    var ref_parts: std.ArrayList([]const u8) = .empty;
    try ref_parts.append(gpa, &full(0, 0));
    for (refs) |r| {
        var body: std.ArrayList(u8) = .empty;
        try body.appendSlice(gpa, &be(u16, r.from));
        try body.appendSlice(gpa, &be(u16, @intCast(r.to.len)));
        for (r.to) |t| try body.appendSlice(gpa, &be(u16, t));
        try ref_parts.append(gpa, try box(gpa, r.type, &.{body.items}));
    }
    const iref = try box(gpa, "iref", ref_parts.items);

    var ipma: std.ArrayList(u8) = .empty;
    try ipma.appendSlice(gpa, &full(0, 0));
    try ipma.appendSlice(gpa, &be(u32, @intCast(items.len)));
    for (items) |it| {
        try ipma.appendSlice(gpa, &be(u16, it.id));
        try ipma.append(gpa, @intCast(it.props.len));
        for (it.props) |p| try ipma.append(gpa, 0x80 | p); // essential
    }
    const iprp = try box(gpa, "iprp", &.{ try box(gpa, "ipco", props), try box(gpa, "ipma", &.{ipma.items}) });

    return box(gpa, "meta", &.{ &full(0, 0), hdlr, pitm, iinf, iloc, iref, iprp });
}

/// A generated HEIC file and what it decodes to.
pub const File = struct {
    data: []const u8,
    width: u32,
    height: u32,
    /// RGBA, row by row
    rgba: []const u8,
};

/// A 2x1 grid of the two `sample` pictures (gray, so RGB equals luma) with a
/// colr box, a clean aperture of 90x30, a quarter turn and a 96x40 alpha
/// plane whose conformance window crops it to 96x32.
pub fn sampleFile(gpa: Allocator) !File {
    const tiles = [2]Sample{ try sample(gpa, false, true), try sample(gpa, true, true) };
    var alpha_pic = try pcmPicture(gpa, 96, 40, 0x414C_5048);
    alpha_pic.crop = .{ 0, 0, 0, 8 };
    const s0 = try encode(gpa, tiles[0].picture);
    const s1 = try encode(gpa, tiles[1].picture);
    const sa = try encode(gpa, alpha_pic);
    const props = [_][]const u8{
        try hvcC(gpa, s0, 1), // 1
        try hvcC(gpa, s1, 1), // 2
        try ispe(gpa, 48, 32), // 3
        try ispe(gpa, 96, 32), // 4
        try clap(gpa, 90, 30), // 5
        try irot(gpa, 1), // 6
        try colrNclx(gpa, 1, 13, 1, true), // 7
        try hvcC(gpa, sa, 0), // 8
        try auxCAlpha(gpa), // 9
    };
    const grid = gridData(1, 2, 96, 32);
    const items = [_]Item{
        .{ .id = 1, .type = "grid", .data = &grid, .props = &.{ 4, 7, 5, 6 } },
        .{ .id = 2, .type = "hvc1", .data = try s0.lengthPrefixed(gpa), .props = &.{ 1, 3 } },
        .{ .id = 3, .type = "hvc1", .data = try s1.lengthPrefixed(gpa), .props = &.{ 2, 3 } },
        .{ .id = 4, .type = "hvc1", .data = try sa.lengthPrefixed(gpa), .props = &.{ 8, 4, 9 } },
    };
    const refs = [_]Ref{
        .{ .type = "dimg", .from = 1, .to = &.{ 2, 3 } },
        .{ .type = "auxl", .from = 4, .to = &.{1} },
    };
    const data = try heif(gpa, 1, &items, &refs, &props);

    // canvas 96x32 (RGB = luma, alpha from the alpha plane), crop 90x30 at
    // (3, 1), then a quarter turn counter-clockwise: 30x90
    const cw = 96;
    const out_w = 30;
    const out_h = 90;
    const rgba = try gpa.alloc(u8, out_w * out_h * 4);
    for (0..out_h) |oy| for (0..out_w) |ox| {
        const x = 3 + (90 - 1 - oy);
        const y = 1 + ox;
        const t = &tiles[x / 48];
        const v = t.expected[0][y * 48 + x % 48];
        const o = rgba[(oy * out_w + ox) * 4 ..][0..4];
        o.* = .{ v, v, v, alpha_pic.y[y * cw + x] };
    };
    return .{ .data = data, .width = out_w, .height = out_h, .rgba = rgba };
}
