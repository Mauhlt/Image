//! VP8 key frame decoder: the image data of a lossy WebP (RFC 6386).
//!
//! Produces the Y, U and V planes (4:2:0) exactly as the spec defines them;
//! colour conversion and alpha are handled by yuv.zig / alpha.zig.
//!
//! Pipeline per macroblock (16x16 luma + 2x 8x8 chroma), in raster order:
//!   modes (first partition) -> coefficient tokens (token partitions)
//!   -> prediction from already-decoded neighbours + inverse WHT/DCT residuals.
//! After all macroblocks: the in-loop deblocking filter.
//!
//! Ported from golang.org/x/image/vp8 (Copyright 2011 The Go Authors, BSD-style
//! license), which follows libwebp; section numbers refer to RFC 6386.
const std = @import("std");
const Error = @import("../error.zig").Error;
const tables = @import("vp8_tables.zig");

pub const Planes = struct {
    width: u32,
    height: u32,
    /// Planes cover whole macroblocks: 16 * mb_w by 16 * mb_h luma samples.
    y: []u8,
    u: []u8,
    v: []u8,
    y_stride: usize,
    uv_stride: usize,

    pub fn deinit(self: Planes, gpa: std.mem.Allocator) void {
        gpa.free(self.y);
        gpa.free(self.u);
        gpa.free(self.v);
    }
};

/// Decodes a `VP8 ` chunk payload. Planes are allocated with `gpa`.
pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Planes {
    var d: Decoder = try .init(gpa, data);
    errdefer d.planes.deinit(gpa);
    defer gpa.free(d.up_mb);
    defer gpa.free(d.mb_filter);
    try d.decodeFrame();
    return d.planes;
}

// ─────────────────────────── Boolean decoder (7) ───────────────────────────

const BoolDecoder = struct {
    buf: []const u8 = &.{},
    pos: usize = 0,
    range_m1: u32 = 254,
    bits: u32 = 0,
    n_bits: u8 = 0,
    eof: bool = false,

    const uniform: u8 = 128;

    fn readBit(self: *BoolDecoder, prob: u8) bool {
        if (self.n_bits < 8) {
            if (self.pos >= self.buf.len) {
                self.eof = true;
                return false;
            }
            self.bits |= @as(u32, self.buf[self.pos]) << @intCast(8 - self.n_bits);
            self.pos += 1;
            self.n_bits += 8;
        }
        const split = ((self.range_m1 * prob) >> 8) + 1;
        const bit = self.bits >= split << 8;
        if (bit) {
            self.range_m1 -= split;
            self.bits -= split << 8;
        } else {
            self.range_m1 = split - 1;
        }
        if (self.range_m1 < 127) {
            // renormalize so that range_m1 is back in 127..254
            const shift = lut_shift[self.range_m1];
            self.range_m1 = lut_range_m1[self.range_m1];
            self.bits <<= @intCast(shift);
            self.n_bits -= shift;
        }
        return bit;
    }

    fn readUint(self: *BoolDecoder, prob: u8, n: u5) u32 {
        var u: u32 = 0;
        var i = n;
        while (i > 0) {
            i -= 1;
            if (self.readBit(prob)) u |= @as(u32, 1) << i;
        }
        return u;
    }

    fn readInt(self: *BoolDecoder, prob: u8, n: u5) i32 {
        const u: i32 = @intCast(self.readUint(prob, n));
        return if (self.readBit(prob)) -u else u;
    }

    fn readOptionalInt(self: *BoolDecoder, prob: u8, n: u5) i32 {
        return if (self.readBit(prob)) self.readInt(prob, n) else 0;
    }

    /// For range_m1 < 127: the shift that renormalizes it, and the new range_m1.
    const lut_shift = blk: {
        var t: [127]u8 = undefined;
        for (&t, 0..) |*s, r| s.* = 7 - std.math.log2_int(u8, @as(u8, @intCast(r + 1)));
        break :blk t;
    };
    const lut_range_m1 = blk: {
        var t: [127]u8 = undefined;
        for (&t, 0..) |*v, r| v.* = @intCast(((r + 1) << lut_shift[r]) - 1);
        break :blk t;
    };
};

// ────────────────────────────── Decoder state ──────────────────────────────

const n_segments = 4;

/// Intra prediction modes, in libwebp / tables.sub_block_mode_prob order.
/// The last three are DC variants for macroblocks on the top/left image edges.
const Pred = enum(u8) { dc, tm, ve, he, rd, vr, ld, vl, hd, hu, dc_no_top, dc_no_left, dc_no_top_left };

/// Coefficient planes (13.3).
const plane_y1_with_y2 = 0;
const plane_y2 = 1;
const plane_uv = 2;
const plane_y1_sans_y2 = 3;

/// Per-macroblock context shared with the neighbours to the right and below.
const MbContext = struct {
    /// sub-block modes along the bottom edge (above) / right edge (left)
    pred: [4]Pred = @splat(.dc),
    /// which 4x4 blocks along the edge had nonzero coefficients (4 luma + 4 chroma bits)
    nz_mask: u8 = 0,
    nz_y16: u8 = 0,
};

const Quant = struct { y1: [2]u16, y2: [2]u16, uv: [2]u16 };

const FilterParam = struct {
    /// edge limit (2 * level + ilevel), interior limit, high-edge-variance threshold
    level: u8 = 0,
    ilevel: u8 = 0,
    hlevel: u8 = 0,
    /// filter the edges inside the macroblock too
    inner: bool = false,
};

// Coefficient layout: 16 luma blocks, 4 U, 4 V, then the luma DC (WHT) block.
const u_coeff_base = 16 * 16;
const v_coeff_base = 16 * 16 + 8 * 8;
const wht_coeff_base = 16 * 16 + 2 * 8 * 8;

// Workspace (`ybr`) layout: rows of 32 samples. Row 0 / column 7 hold the
// neighbouring pixels above / to the left (see prepareWorkspace).
const ybr_y_row = 1;
const ybr_y_col = 8;
const ybr_u_row = 18;
const ybr_u_col = 8;
const ybr_v_row = 18;
const ybr_v_col = 24;

const Decoder = struct {
    gpa: std.mem.Allocator,
    planes: Planes,
    mb_w: usize,
    mb_h: usize,

    first: BoolDecoder = .{},
    parts: [8]BoolDecoder = @splat(.{}),
    n_parts: usize = 1,

    // segment header (9.3)
    use_segment: bool = false,
    update_map: bool = false,
    relative_delta: bool = false,
    seg_quant: [n_segments]i8 = @splat(0),
    seg_filter: [n_segments]i8 = @splat(0),
    seg_prob: [3]u8 = @splat(255),

    // filter header (9.4)
    simple_filter: bool = false,
    filter_level: i8 = 0,
    sharpness: u8 = 0,
    use_lf_delta: bool = false,
    ref_lf_delta: [4]i8 = @splat(0),
    mode_lf_delta: [4]i8 = @splat(0),

    quant: [n_segments]Quant = undefined,
    token_prob: [4][8][3][11]u8 = tables.default_token_prob,
    use_skip_prob: bool = false,
    skip_prob: u8 = 0,

    /// [segment][is 4x4-predicted]
    filter_params: [n_segments][2]FilterParam = @splat(@splat(.{})),
    mb_filter: []FilterParam,

    segment: u8 = 0,
    left_mb: MbContext = .{},
    up_mb: []MbContext,

    // current macroblock
    nz_dc_mask: u32 = 0,
    nz_ac_mask: u32 = 0,
    use_pred_y16: bool = false,
    pred_y16: Pred = .dc,
    pred_c8: Pred = .dc,
    pred_y4: [4][4]Pred = @splat(@splat(.dc)),
    coeff: [16 * 16 + 2 * 8 * 8 + 4 * 4]i16 = @splat(0),
    ybr: [1 + 16 + 1 + 8][32]u8 = @splat(@splat(0)),

    /// Frame tag and key frame header (9.1). `data` is the VP8 chunk payload.
    fn init(gpa: std.mem.Allocator, data: []const u8) !Decoder {
        if (data.len < 10) return Error.UnexpectedEndOfData;
        const tag = @as(u32, data[0]) | @as(u32, data[1]) << 8 | @as(u32, data[2]) << 16;
        if (tag & 1 != 0) return Error.UnsupportedFeature; // inter frame: video only
        if (!std.mem.eql(u8, data[3..6], &.{ 0x9d, 0x01, 0x2a })) return Error.UnexpectedSignature;
        const first_len: usize = tag >> 5;
        const width: u32 = std.mem.readInt(u16, data[6..8], .little) & 0x3FFF;
        const height: u32 = std.mem.readInt(u16, data[8..10], .little) & 0x3FFF;
        if (width == 0 or height == 0) return Error.InvalidDimensions;
        if (10 + first_len > data.len) return Error.UnexpectedEndOfData;

        const mb_w = (@as(usize, width) + 15) / 16;
        const mb_h = (@as(usize, height) + 15) / 16;
        const y = try gpa.alloc(u8, 16 * mb_w * 16 * mb_h);
        errdefer gpa.free(y);
        const u = try gpa.alloc(u8, 8 * mb_w * 8 * mb_h);
        errdefer gpa.free(u);
        const v = try gpa.alloc(u8, 8 * mb_w * 8 * mb_h);
        errdefer gpa.free(v);
        const mb_filter = try gpa.alloc(FilterParam, mb_w * mb_h);
        errdefer gpa.free(mb_filter);
        const up_mb = try gpa.alloc(MbContext, mb_w);
        errdefer gpa.free(up_mb);
        @memset(up_mb, .{});

        var d: Decoder = .{
            .gpa = gpa,
            .planes = .{ .width = width, .height = height, .y = y, .u = u, .v = v, .y_stride = 16 * mb_w, .uv_stride = 8 * mb_w },
            .mb_w = mb_w,
            .mb_h = mb_h,
            .mb_filter = mb_filter,
            .up_mb = up_mb,
        };
        d.first = .{ .buf = data[10..][0..first_len] };
        try d.parseHeaders(data[10 + first_len ..]);
        return d;
    }

    fn parseHeaders(d: *Decoder, rest: []const u8) !void {
        const fp = &d.first;
        _ = fp.readBit(BoolDecoder.uniform); // colour space (always YUV)
        _ = fp.readBit(BoolDecoder.uniform); // clamping type (always clamp)
        d.parseSegmentHeader();
        d.parseFilterHeader();
        try d.parsePartitions(rest);
        d.parseQuant();
        _ = fp.readBit(BoolDecoder.uniform); // refresh entropy probs: key frames only, ignored
        d.parseTokenProb();
        d.use_skip_prob = fp.readBit(BoolDecoder.uniform);
        if (d.use_skip_prob) d.skip_prob = @intCast(fp.readUint(BoolDecoder.uniform, 8));
        if (fp.eof) return Error.UnexpectedEndOfData;
    }

    fn parseSegmentHeader(d: *Decoder) void {
        const fp = &d.first;
        d.use_segment = fp.readBit(BoolDecoder.uniform);
        if (!d.use_segment) return;
        d.update_map = fp.readBit(BoolDecoder.uniform);
        if (fp.readBit(BoolDecoder.uniform)) { // update segment feature data
            d.relative_delta = !fp.readBit(BoolDecoder.uniform);
            for (&d.seg_quant) |*q| q.* = @intCast(fp.readOptionalInt(BoolDecoder.uniform, 7));
            for (&d.seg_filter) |*f| f.* = @intCast(fp.readOptionalInt(BoolDecoder.uniform, 6));
        }
        if (!d.update_map) return;
        for (&d.seg_prob) |*p| {
            p.* = if (fp.readBit(BoolDecoder.uniform)) @intCast(fp.readUint(BoolDecoder.uniform, 8)) else 255;
        }
    }

    fn parseFilterHeader(d: *Decoder) void {
        const fp = &d.first;
        d.simple_filter = fp.readBit(BoolDecoder.uniform);
        d.filter_level = @intCast(fp.readUint(BoolDecoder.uniform, 6));
        d.sharpness = @intCast(fp.readUint(BoolDecoder.uniform, 3));
        d.use_lf_delta = fp.readBit(BoolDecoder.uniform);
        if (d.use_lf_delta and fp.readBit(BoolDecoder.uniform)) {
            for (&d.ref_lf_delta) |*x| x.* = @intCast(fp.readOptionalInt(BoolDecoder.uniform, 6));
            for (&d.mode_lf_delta) |*x| x.* = @intCast(fp.readOptionalInt(BoolDecoder.uniform, 6));
        }
        if (d.filter_level != 0) d.computeFilterParams();
    }

    /// 9.5: token partition count, then all but the last partition's 24-bit sizes.
    fn parsePartitions(d: *Decoder, rest: []const u8) !void {
        d.n_parts = @as(usize, 1) << @intCast(d.first.readUint(BoolDecoder.uniform, 2));
        const sizes_len = 3 * (d.n_parts - 1);
        if (rest.len < sizes_len) return Error.UnexpectedEndOfData;
        var buf = rest[sizes_len..];
        for (0..d.n_parts) |i| {
            const len = if (i + 1 == d.n_parts) buf.len else std.mem.readInt(u24, rest[3 * i ..][0..3], .little);
            if (len > buf.len) return Error.UnexpectedEndOfData;
            d.parts[i] = .{ .buf = buf[0..len] };
            buf = buf[len..];
        }
    }

    /// 9.6 / 14.1
    fn parseQuant(d: *Decoder) void {
        const fp = &d.first;
        const base: i32 = @intCast(fp.readUint(BoolDecoder.uniform, 7));
        const dq_y1_dc = fp.readOptionalInt(BoolDecoder.uniform, 4);
        const dq_y2_dc = fp.readOptionalInt(BoolDecoder.uniform, 4);
        const dq_y2_ac = fp.readOptionalInt(BoolDecoder.uniform, 4);
        const dq_uv_dc = fp.readOptionalInt(BoolDecoder.uniform, 4);
        const dq_uv_ac = fp.readOptionalInt(BoolDecoder.uniform, 4);
        for (&d.quant, 0..) |*q, i| {
            var qi = base;
            if (d.use_segment) qi = if (d.relative_delta) qi + d.seg_quant[i] else d.seg_quant[i];
            const y2_ac = @as(u32, ac_table[clampIndex(qi + dq_y2_ac, 127)]) * 155 / 100;
            q.* = .{
                .y1 = .{ dc_table[clampIndex(qi + dq_y1_dc, 127)], ac_table[clampIndex(qi, 127)] },
                .y2 = .{ dc_table[clampIndex(qi + dq_y2_dc, 127)] * 2, @intCast(@max(y2_ac, 8)) },
                // the reference decoder caps the chroma DC index at 117 (= quantizer 132)
                .uv = .{ dc_table[clampIndex(qi + dq_uv_dc, 117)], ac_table[clampIndex(qi + dq_uv_ac, 127)] },
            };
        }
    }

    fn clampIndex(x: i32, max: i32) usize {
        return @intCast(std.math.clamp(x, 0, max));
    }

    /// 13.4
    fn parseTokenProb(d: *Decoder) void {
        for (&d.token_prob, tables.token_update_prob) |*plane, uplane| {
            for (plane, uplane) |*band, uband| for (band, uband) |*ctx, uctx| for (ctx, uctx) |*p, up| {
                if (d.first.readBit(up)) p.* = @intCast(d.first.readUint(BoolDecoder.uniform, 8));
            };
        }
    }

    /// 15.4 (key frames).
    fn computeFilterParams(d: *Decoder) void {
        for (&d.filter_params, 0..) |*seg, i| {
            var base: i32 = d.filter_level;
            if (d.use_segment) {
                base = d.seg_filter[i];
                if (d.relative_delta) base += d.filter_level;
            }
            for (seg, 0..) |*p, j| {
                p.inner = j != 0;
                var level = base;
                if (d.use_lf_delta) {
                    level += d.ref_lf_delta[0]; // intra frame
                    if (j != 0) level += d.mode_lf_delta[0]; // 4x4 prediction
                }
                if (level <= 0) {
                    p.level = 0;
                    continue;
                }
                level = @min(level, 63);
                var ilevel = level;
                if (d.sharpness > 0) {
                    ilevel >>= if (d.sharpness > 4) 2 else 1;
                    ilevel = @min(ilevel, 9 - @as(i32, d.sharpness));
                }
                ilevel = @max(ilevel, 1);
                p.ilevel = @intCast(ilevel);
                p.level = @intCast(2 * level + ilevel);
                p.hlevel = if (level < 15) 0 else if (level < 40) 1 else 2;
            }
        }
    }

    fn decodeFrame(d: *Decoder) !void {
        for (0..d.mb_h) |mby| {
            d.left_mb = .{};
            for (0..d.mb_w) |mbx| {
                const skip = d.reconstruct(mbx, mby);
                var f = d.filter_params[d.segment][@intFromBool(!d.use_pred_y16)];
                f.inner = f.inner or !skip;
                d.mb_filter[d.mb_w * mby + mbx] = f;
            }
        }
        if (d.first.eof) return Error.UnexpectedEndOfData;
        for (d.parts[0..d.n_parts]) |p| if (p.eof) return Error.UnexpectedEndOfData;
        // 15: skipped entirely when the frame-level filter level is 0
        if (d.filter_level != 0) {
            if (d.simple_filter) d.simpleFilter() else d.normalFilter();
        }
    }

    // ─────────────────────────── Macroblocks ───────────────────────────

    /// Decodes one macroblock into the planes. Returns whether it had no
    /// coefficients (then its inner edges need no filtering).
    fn reconstruct(d: *Decoder, mbx: usize, mby: usize) bool {
        const fp = &d.first;
        if (d.update_map) {
            d.segment = if (!fp.readBit(d.seg_prob[0]))
                @intCast(fp.readUint(d.seg_prob[1], 1))
            else
                @intCast(fp.readUint(d.seg_prob[2], 1) + 2);
        }
        var skip = d.use_skip_prob and fp.readBit(d.skip_prob);

        @memset(&d.coeff, 0);
        d.prepareWorkspace(mbx, mby);
        d.use_pred_y16 = fp.readBit(145);
        if (d.use_pred_y16) d.parsePredModeY16(mbx) else d.parsePredModeY4(mbx);
        d.parsePredModeC8();

        if (!skip) {
            skip = d.parseResiduals(mbx, mby);
        } else {
            if (d.use_pred_y16) {
                d.left_mb.nz_y16 = 0;
                d.up_mb[mbx].nz_y16 = 0;
            }
            d.left_mb.nz_mask = 0;
            d.up_mb[mbx].nz_mask = 0;
            d.nz_dc_mask = 0;
            d.nz_ac_mask = 0;
        }

        d.reconstructMacroblock(mbx, mby);
        const p = &d.planes;
        for (0..16) |y| @memcpy(p.y[(mby * 16 + y) * p.y_stride + mbx * 16 ..][0..16], d.ybr[ybr_y_row + y][ybr_y_col..][0..16]);
        for (0..8) |y| {
            @memcpy(p.u[(mby * 8 + y) * p.uv_stride + mbx * 8 ..][0..8], d.ybr[ybr_u_row + y][ybr_u_col..][0..8]);
            @memcpy(p.v[(mby * 8 + y) * p.uv_stride + mbx * 8 ..][0..8], d.ybr[ybr_v_row + y][ybr_v_col..][0..8]);
        }
        return skip;
    }

    /// Fills the workspace border: row 0 (and row 17 for chroma) gets the pixels
    /// above, column 7 (and 23) the pixels to the left. Outside the image those
    /// are 127 above and 129 to the left (12.2). The 4 samples above-right of the
    /// macroblock (columns 24..27) are also used by sub-blocks in rows 4, 8, 12.
    fn prepareWorkspace(d: *Decoder, mbx: usize, mby: usize) void {
        const ybr = &d.ybr;
        if (mbx == 0) {
            for (0..17) |y| ybr[y][7] = 0x81;
            for (17..26) |y| {
                ybr[y][7] = 0x81;
                ybr[y][23] = 0x81;
            }
        } else {
            for (0..17) |y| ybr[y][7] = ybr[y][7 + 16];
            for (17..26) |y| {
                ybr[y][7] = ybr[y][15];
                ybr[y][23] = ybr[y][31];
            }
        }
        if (mby == 0) {
            @memset(ybr[0][7..28], 0x7f);
            @memset(ybr[17][7..16], 0x7f);
            @memset(ybr[17][23..32], 0x7f);
        } else {
            const p = &d.planes;
            const y_row = (16 * mby - 1) * p.y_stride + 16 * mbx;
            const c_row = (8 * mby - 1) * p.uv_stride + 8 * mbx;
            @memcpy(ybr[0][8..24], p.y[y_row..][0..16]);
            @memcpy(ybr[17][8..16], p.u[c_row..][0..8]);
            @memcpy(ybr[17][24..32], p.v[c_row..][0..8]);
            // above-right: from the next macroblock, or repeated at the right edge
            if (mbx == d.mb_w - 1) {
                @memset(ybr[0][24..28], p.y[y_row + 15]);
            } else {
                @memcpy(ybr[0][24..28], p.y[y_row + 16 ..][0..4]);
            }
        }
        for ([_]usize{ 4, 8, 12 }) |y| ybr[y][24..28].* = ybr[0][24..28].*;
    }

    fn parsePredModeY16(d: *Decoder, mbx: usize) void {
        const fp = &d.first;
        const p: Pred = if (!fp.readBit(156))
            (if (!fp.readBit(163)) .dc else .ve)
        else if (!fp.readBit(128)) .he else .tm;
        d.up_mb[mbx].pred = @splat(p);
        d.left_mb.pred = @splat(p);
        d.pred_y16 = p;
    }

    fn parsePredModeC8(d: *Decoder) void {
        const fp = &d.first;
        d.pred_c8 = if (!fp.readBit(142)) .dc else if (!fp.readBit(114)) .ve else if (!fp.readBit(183)) .he else .tm;
    }

    /// 11.3: each sub-block's mode is coded relative to the modes above and left.
    fn parsePredModeY4(d: *Decoder, mbx: usize) void {
        const fp = &d.first;
        for (0..4) |j| {
            var p = d.left_mb.pred[j];
            for (0..4) |i| {
                const prob = &tables.sub_block_mode_prob[@intFromEnum(d.up_mb[mbx].pred[i])][@intFromEnum(p)];
                p = if (!fp.readBit(prob[0])) .dc else if (!fp.readBit(prob[1])) .tm else if (!fp.readBit(prob[2])) .ve else if (!fp.readBit(prob[3]))
                    (if (!fp.readBit(prob[4])) .he else if (!fp.readBit(prob[5])) .rd else .vr)
                else if (!fp.readBit(prob[6])) .ld else if (!fp.readBit(prob[7])) .vl else if (!fp.readBit(prob[8])) .hd else .hu;
                d.pred_y4[j][i] = p;
                d.up_mb[mbx].pred[i] = p;
            }
            d.left_mb.pred[j] = p;
        }
    }

    // ─────────────────────────── Residuals (13) ───────────────────────────

    /// Parses one 4x4 block's tokens into `coeff[base..][0..16]` (dequantized).
    /// `ctx` = number of neighbours (left + above) with nonzero coefficients.
    /// Returns 1 if any coefficient was nonzero.
    fn parseResiduals4(d: *Decoder, r: *BoolDecoder, plane: usize, ctx: u8, quant: [2]u16, skip_dc: bool, base: usize) u8 {
        const prob = &d.token_prob[plane];
        var n: usize = @intFromBool(skip_dc);
        var p = &prob[bands[n]][ctx];
        if (!r.readBit(p[0])) return 0; // no coefficients at all
        while (n != 16) {
            n += 1;
            if (!r.readBit(p[1])) { // DCT_0
                p = &prob[bands[n]][0];
                continue;
            }
            var v: u32 = undefined;
            if (!r.readBit(p[2])) {
                v = 1;
                p = &prob[bands[n]][1];
            } else {
                if (!r.readBit(p[3])) {
                    v = if (!r.readBit(p[4])) 2 else 3 + r.readUint(p[5], 1);
                } else if (!r.readBit(p[6])) {
                    v = if (!r.readBit(p[7]))
                        5 + r.readUint(159, 1) // category 1
                    else
                        7 + 2 * r.readUint(165, 1) + r.readUint(145, 1); // category 2
                } else {
                    // categories 3..6: extra bits with fixed probabilities
                    const b1 = r.readUint(p[8], 1);
                    const b0 = r.readUint(p[9 + b1], 1);
                    const cat = 2 * b1 + b0;
                    v = 0;
                    for (cat_probs[cat]) |cp| {
                        if (cp == 0) break;
                        v = 2 * v + r.readUint(cp, 1);
                    }
                    v += 3 + (@as(u32, 8) << @intCast(cat));
                }
                p = &prob[bands[n]][2];
            }
            const z = zigzag[n - 1];
            var c: i32 = @as(i32, @intCast(v)) * quant[@intFromBool(z > 0)];
            if (r.readBit(BoolDecoder.uniform)) c = -c;
            d.coeff[base + z] = @truncate(c);
            if (n == 16 or !r.readBit(p[0])) return 1; // EOB
        }
        return 1;
    }

    /// Returns whether the macroblock had no nonzero coefficients.
    fn parseResiduals(d: *Decoder, mbx: usize, mby: usize) bool {
        const part = &d.parts[mby & (d.n_parts - 1)];
        const q = d.quant[d.segment];
        var plane: usize = plane_y1_sans_y2;
        const up = &d.up_mb[mbx];

        if (d.use_pred_y16) {
            // the 16 luma DCs are coded together and inverse-WHT'd into the blocks
            const nz = d.parseResiduals4(part, plane_y2, d.left_mb.nz_y16 + up.nz_y16, q.y2, false, wht_coeff_base);
            d.left_mb.nz_y16 = nz;
            up.nz_y16 = nz;
            d.inverseWht16();
            plane = plane_y1_with_y2;
        }

        var nz_dc: [4]u8 = undefined;
        var nz_ac: [4]u8 = undefined;
        var nz_dc_mask: u32 = 0;
        var nz_ac_mask: u32 = 0;
        var base: usize = 0;

        var lnz = unpack(d.left_mb.nz_mask & 0x0f);
        var unz = unpack(up.nz_mask & 0x0f);
        for (0..4) |y| {
            var nz = lnz[y];
            for (0..4) |x| {
                nz = d.parseResiduals4(part, plane, nz + unz[x], q.y1, d.use_pred_y16, base);
                unz[x] = nz;
                nz_ac[x] = nz;
                nz_dc[x] = @intFromBool(d.coeff[base] != 0);
                base += 16;
            }
            lnz[y] = nz;
            nz_dc_mask |= pack(nz_dc, @intCast(y * 4));
            nz_ac_mask |= pack(nz_ac, @intCast(y * 4));
        }
        var lnz_mask = pack(lnz, 0);
        var unz_mask = pack(unz, 0);

        lnz = unpack(d.left_mb.nz_mask >> 4);
        unz = unpack(up.nz_mask >> 4);
        var c: usize = 0;
        while (c < 4) : (c += 2) { // U then V, 2x2 blocks each
            for (0..2) |y| {
                var nz = lnz[y + c];
                for (0..2) |x| {
                    nz = d.parseResiduals4(part, plane_uv, nz + unz[x + c], q.uv, false, base);
                    unz[x + c] = nz;
                    nz_ac[y * 2 + x] = nz;
                    nz_dc[y * 2 + x] = @intFromBool(d.coeff[base] != 0);
                    base += 16;
                }
                lnz[y + c] = nz;
            }
            nz_dc_mask |= pack(nz_dc, @intCast(16 + c * 2));
            nz_ac_mask |= pack(nz_ac, @intCast(16 + c * 2));
        }
        lnz_mask |= pack(lnz, 4);
        unz_mask |= pack(unz, 4);

        d.left_mb.nz_mask = @intCast(lnz_mask);
        up.nz_mask = @intCast(unz_mask);
        d.nz_dc_mask = nz_dc_mask;
        d.nz_ac_mask = nz_ac_mask;
        return nz_dc_mask == 0 and nz_ac_mask == 0;
    }

    fn reconstructMacroblock(d: *Decoder, mbx: usize, mby: usize) void {
        // 16x16: one prediction, then the residuals. 4x4: each sub-block is
        // predicted from its already-reconstructed neighbours, so in order.
        if (d.use_pred_y16) d.predictBlock(16, edgePred(mbx, mby, d.pred_y16), ybr_y_row, ybr_y_col);
        for (0..4) |j| for (0..4) |i| {
            const n = 4 * j + i;
            const y = 4 * j + ybr_y_row;
            const x = 4 * i + ybr_y_col;
            if (!d.use_pred_y16) d.predict4(d.pred_y4[j][i], y, x);
            d.addResidual4(y, x, 16 * n, @as(u32, 1) << @intCast(n));
        };
        const pc = edgePred(mbx, mby, d.pred_c8);
        d.predictBlock(8, pc, ybr_u_row, ybr_u_col);
        d.predictBlock(8, pc, ybr_v_row, ybr_v_col);
        for (0..4) |k| {
            const bx = 4 * (k & 1);
            const by = 4 * (k >> 1);
            d.addResidual4(ybr_u_row + by, ybr_u_col + bx, u_coeff_base + 16 * k, @as(u32, 1) << @intCast(16 + k));
            d.addResidual4(ybr_v_row + by, ybr_v_col + bx, v_coeff_base + 16 * k, @as(u32, 1) << @intCast(20 + k));
        }
    }

    /// Adds a 4x4 block's inverse transform, if it has any coefficients.
    fn addResidual4(d: *Decoder, y: usize, x: usize, base: usize, mask: u32) void {
        if (d.nz_ac_mask & mask != 0) {
            d.inverseDct4(y, x, base);
        } else if (d.nz_dc_mask & mask != 0) {
            const dc = (@as(i32, d.coeff[base]) + 4) >> 3;
            for (0..4) |j| for (0..4) |i| {
                d.ybr[y + j][x + i] = clip8(@as(i32, d.ybr[y + j][x + i]) + dc);
            };
        }
    }

    // ───────────────────────── Transforms (14.3, 14.4) ─────────────────────────

    fn inverseDct4(d: *Decoder, y: usize, x: usize, base: usize) void {
        const c1 = 85627; // 65536 * cos(pi/8) * sqrt(2)
        const c2 = 35468; // 65536 * sin(pi/8) * sqrt(2)
        var m: [4][4]i32 = undefined;
        for (0..4) |i| {
            const in = d.coeff[base + i ..];
            const a = @as(i32, in[0]) + in[8];
            const b = @as(i32, in[0]) - in[8];
            const c = ((@as(i32, in[4]) * c2) >> 16) - ((@as(i32, in[12]) * c1) >> 16);
            const e = ((@as(i32, in[4]) * c1) >> 16) + ((@as(i32, in[12]) * c2) >> 16);
            m[i] = .{ a + e, b + c, b - c, a - e };
        }
        for (0..4) |j| {
            const dc = m[0][j] + 4;
            const a = dc + m[2][j];
            const b = dc - m[2][j];
            const c = ((m[1][j] * c2) >> 16) - ((m[3][j] * c1) >> 16);
            const e = ((m[1][j] * c1) >> 16) + ((m[3][j] * c2) >> 16);
            const row = &d.ybr[y + j];
            for ([4]i32{ a + e, b + c, b - c, a - e }, 0..) |r, i| row[x + i] = clip8(@as(i32, row[x + i]) + (r >> 3));
        }
    }

    /// Spreads the 16 luma DCs (Y2 block) into the DC slot of each luma block.
    fn inverseWht16(d: *Decoder) void {
        const in = d.coeff[wht_coeff_base..];
        var m: [16]i32 = undefined;
        for (0..4) |i| {
            const a0 = @as(i32, in[0 + i]) + in[12 + i];
            const a1 = @as(i32, in[4 + i]) + in[8 + i];
            const a2 = @as(i32, in[4 + i]) - in[8 + i];
            const a3 = @as(i32, in[0 + i]) - in[12 + i];
            m[0 + i] = a0 + a1;
            m[8 + i] = a0 - a1;
            m[4 + i] = a3 + a2;
            m[12 + i] = a3 - a2;
        }
        var out: usize = 0;
        for (0..4) |i| {
            const dc = m[0 + i * 4] + 3;
            const a0 = dc + m[3 + i * 4];
            const a1 = m[1 + i * 4] + m[2 + i * 4];
            const a2 = m[1 + i * 4] - m[2 + i * 4];
            const a3 = dc - m[3 + i * 4];
            d.coeff[out + 0] = @truncate((a0 + a1) >> 3);
            d.coeff[out + 16] = @truncate((a3 + a2) >> 3);
            d.coeff[out + 32] = @truncate((a0 - a1) >> 3);
            d.coeff[out + 48] = @truncate((a3 - a2) >> 3);
            out += 64;
        }
    }

    // ───────────────────────── Intra prediction (12) ─────────────────────────

    /// 16x16 luma or 8x8 chroma prediction.
    fn predictBlock(d: *Decoder, comptime size: usize, mode: Pred, y: usize, x: usize) void {
        const ybr = &d.ybr;
        switch (mode) {
            .dc, .dc_no_top, .dc_no_left => {
                var sum: u32 = 0;
                var count: u32 = 0;
                if (mode != .dc_no_top) {
                    for (0..size) |i| sum += ybr[y - 1][x + i];
                    count += size;
                }
                if (mode != .dc_no_left) {
                    for (0..size) |j| sum += ybr[y + j][x - 1];
                    count += size;
                }
                fill(ybr, size, y, x, @intCast((sum + count / 2) / count));
            },
            .dc_no_top_left => fill(ybr, size, y, x, 0x80),
            .tm => for (0..size) |j| for (0..size) |i| {
                ybr[y + j][x + i] = clip8(@as(i32, ybr[y + j][x - 1]) + ybr[y - 1][x + i] - ybr[y - 1][x - 1]);
            },
            .ve => for (0..size) |j| {
                @memcpy(ybr[y + j][x..][0..size], ybr[y - 1][x..][0..size]);
            },
            .he => for (0..size) |j| @memset(ybr[y + j][x..][0..size], ybr[y + j][x - 1]),
            else => unreachable, // 4x4-only modes
        }
    }

    fn fill(ybr: *[26][32]u8, size: usize, y: usize, x: usize, v: u8) void {
        for (0..size) |j| @memset(ybr[y + j][x..][0..size], v);
    }

    /// 12.3: 4x4 luma sub-block prediction. With the spec's naming, the
    /// neighbours are the corner M, the row above A..H (T[0..8], including 4
    /// above-right) and the column to the left I..L (L[0..4]).
    fn predict4(d: *Decoder, mode: Pred, y: usize, x: usize) void {
        const ybr = &d.ybr;
        var t: [8]i32 = undefined;
        for (&t, 0..) |*v, i| v.* = ybr[y - 1][x + i];
        var l: [4]i32 = undefined;
        for (&l, 0..) |*v, j| v.* = ybr[y + j][x - 1];
        const m: i32 = ybr[y - 1][x - 1];

        var b: [4][4]i32 = undefined; // b[row][col]
        switch (mode) {
            .dc => {
                var sum: i32 = 4;
                for (t[0..4]) |v| sum += v;
                for (l) |v| sum += v;
                b = @splat(@splat(sum >> 3));
            },
            .tm => for (0..4) |j| for (0..4) |i| {
                b[j][i] = std.math.clamp(l[j] + t[i] - m, 0, 255);
            },
            .ve => {
                const row = [4]i32{ avg3(m, t[0], t[1]), avg3(t[0], t[1], t[2]), avg3(t[1], t[2], t[3]), avg3(t[2], t[3], t[4]) };
                b = @splat(row);
            },
            .he => {
                const col = [4]i32{ avg3(m, l[0], l[1]), avg3(l[0], l[1], l[2]), avg3(l[1], l[2], l[3]), avg3(l[2], l[3], l[3]) };
                for (0..4) |j| b[j] = @splat(col[j]);
            },
            .rd => {
                // down-right diagonal along the edge L3 L2 L1 L0 M A B C D
                const e = [9]i32{ l[3], l[2], l[1], l[0], m, t[0], t[1], t[2], t[3] };
                for (0..4) |j| for (0..4) |i| {
                    b[j][i] = avg3(e[3 - j + i], e[4 - j + i], e[5 - j + i]);
                };
            },
            .ld => for (0..4) |j| for (0..4) |i| {
                // down-left diagonal along A..H, the last sample repeated
                const k = i + j;
                b[j][i] = avg3(t[k], t[k + 1], t[@min(k + 2, 7)]);
            },
            .vr => b = .{
                .{ avg2(m, t[0]), avg2(t[0], t[1]), avg2(t[1], t[2]), avg2(t[2], t[3]) },
                .{ avg3(l[0], m, t[0]), avg3(m, t[0], t[1]), avg3(t[0], t[1], t[2]), avg3(t[1], t[2], t[3]) },
                .{ avg3(l[1], l[0], m), avg2(m, t[0]), avg2(t[0], t[1]), avg2(t[1], t[2]) },
                .{ avg3(l[2], l[1], l[0]), avg3(l[0], m, t[0]), avg3(m, t[0], t[1]), avg3(t[0], t[1], t[2]) },
            },
            .vl => b = .{
                .{ avg2(t[0], t[1]), avg2(t[1], t[2]), avg2(t[2], t[3]), avg2(t[3], t[4]) },
                .{ avg3(t[0], t[1], t[2]), avg3(t[1], t[2], t[3]), avg3(t[2], t[3], t[4]), avg3(t[3], t[4], t[5]) },
                .{ avg2(t[1], t[2]), avg2(t[2], t[3]), avg2(t[3], t[4]), avg3(t[4], t[5], t[6]) },
                .{ avg3(t[1], t[2], t[3]), avg3(t[2], t[3], t[4]), avg3(t[3], t[4], t[5]), avg3(t[5], t[6], t[7]) },
            },
            .hd => b = .{
                .{ avg2(l[0], m), avg3(l[0], m, t[0]), avg3(m, t[0], t[1]), avg3(t[0], t[1], t[2]) },
                .{ avg2(l[1], l[0]), avg3(l[1], l[0], m), avg2(l[0], m), avg3(l[0], m, t[0]) },
                .{ avg2(l[2], l[1]), avg3(l[2], l[1], l[0]), avg2(l[1], l[0]), avg3(l[1], l[0], m) },
                .{ avg2(l[3], l[2]), avg3(l[3], l[2], l[1]), avg2(l[2], l[1]), avg3(l[2], l[1], l[0]) },
            },
            .hu => b = .{
                .{ avg2(l[0], l[1]), avg3(l[0], l[1], l[2]), avg2(l[1], l[2]), avg3(l[1], l[2], l[3]) },
                .{ avg2(l[1], l[2]), avg3(l[1], l[2], l[3]), avg2(l[2], l[3]), avg3(l[2], l[3], l[3]) },
                .{ avg2(l[2], l[3]), avg3(l[2], l[3], l[3]), l[3], l[3] },
                .{ l[3], l[3], l[3], l[3] },
            },
            else => unreachable, // 16x16 / 8x8 edge variants
        }
        for (0..4) |j| for (0..4) |i| {
            ybr[y + j][x + i] = @intCast(b[j][i]);
        };
    }

    fn avg2(a: i32, b: i32) i32 {
        return (a + b + 1) >> 1;
    }
    fn avg3(a: i32, b: i32, c: i32) i32 {
        return (a + 2 * b + c + 2) >> 2;
    }

    /// DC prediction on the image edges averages only the neighbours that exist.
    fn edgePred(mbx: usize, mby: usize, p: Pred) Pred {
        if (p != .dc) return p;
        if (mbx == 0) return if (mby == 0) .dc_no_top_left else .dc_no_left;
        if (mby == 0) return .dc_no_top;
        return .dc;
    }

    // ───────────────────────────── Loop filter (15) ─────────────────────────────

    fn simpleFilter(d: *Decoder) void {
        const ys = d.planes.y_stride;
        for (0..d.mb_h) |mby| for (0..d.mb_w) |mbx| {
            const f = d.mb_filter[d.mb_w * mby + mbx];
            if (f.level == 0) continue;
            const l: i32 = f.level;
            const yi = (mby * ys + mbx) * 16;
            if (mbx > 0) filter2(d.planes.y, l + 4, yi, ys, 1);
            if (f.inner) for ([_]usize{ 4, 8, 12 }) |o| filter2(d.planes.y, l, yi + o, ys, 1);
            if (mby > 0) filter2(d.planes.y, l + 4, yi, 1, ys);
            if (f.inner) for ([_]usize{ 4, 8, 12 }) |o| filter2(d.planes.y, l, yi + ys * o, 1, ys);
        };
    }

    fn normalFilter(d: *Decoder) void {
        const ys = d.planes.y_stride;
        const cs = d.planes.uv_stride;
        const p = &d.planes;
        for (0..d.mb_h) |mby| for (0..d.mb_w) |mbx| {
            const f = d.mb_filter[d.mb_w * mby + mbx];
            if (f.level == 0) continue;
            const l: i32 = f.level;
            const il: i32 = f.ilevel;
            const hl: i32 = f.hlevel;
            const yi = (mby * ys + mbx) * 16;
            const ci = (mby * cs + mbx) * 8;
            // vertical edges (filtering across columns), then horizontal ones
            if (mbx > 0) {
                filter246(p.y, 16, l + 4, il, hl, yi, ys, 1, false);
                filter246(p.u, 8, l + 4, il, hl, ci, cs, 1, false);
                filter246(p.v, 8, l + 4, il, hl, ci, cs, 1, false);
            }
            if (f.inner) {
                for ([_]usize{ 4, 8, 12 }) |o| filter246(p.y, 16, l, il, hl, yi + o, ys, 1, true);
                filter246(p.u, 8, l, il, hl, ci + 4, cs, 1, true);
                filter246(p.v, 8, l, il, hl, ci + 4, cs, 1, true);
            }
            if (mby > 0) {
                filter246(p.y, 16, l + 4, il, hl, yi, 1, ys, false);
                filter246(p.u, 8, l + 4, il, hl, ci, 1, cs, false);
                filter246(p.v, 8, l + 4, il, hl, ci, 1, cs, false);
            }
            if (f.inner) {
                for ([_]usize{ 4, 8, 12 }) |o| filter246(p.y, 16, l, il, hl, yi + ys * o, 1, ys, true);
                filter246(p.u, 8, l, il, hl, ci + cs * 4, 1, cs, true);
                filter246(p.v, 8, l, il, hl, ci + cs * 4, 1, cs, true);
            }
        };
    }
};

/// Simple filter: adjusts the 2 pixels either side of an edge (15.2).
/// `along` steps along the edge, `across` steps across it.
fn filter2(pix: []u8, level: i32, start: usize, along: usize, across: usize) void {
    var index = start;
    for (0..16) |_| {
        defer index += along;
        const p1: i32 = pix[index - 2 * across];
        const p0: i32 = pix[index - across];
        const q0: i32 = pix[index];
        const q1: i32 = pix[index + across];
        if ((@abs(p0 - q0) << 1) + (@abs(p1 - q1) >> 1) > level) continue;
        const a = 3 * (q0 - p0) + clamp127(p1 - q1);
        pix[index - across] = clip8(p0 + clamp15((a + 3) >> 3));
        pix[index] = clip8(q0 - clamp15((a + 4) >> 3));
    }
}

/// Normal filter (15.3): 2, 4 (inner edges) or 6 (macroblock edges) pixels.
fn filter246(pix: []u8, n: usize, level: i32, ilevel: i32, hlevel: i32, start: usize, along: usize, across: usize, four_not_six: bool) void {
    var index = start;
    for (0..n) |_| {
        defer index += along;
        const p3: i32 = pix[index - 4 * across];
        const p2: i32 = pix[index - 3 * across];
        const p1: i32 = pix[index - 2 * across];
        const p0: i32 = pix[index - across];
        const q0: i32 = pix[index];
        const q1: i32 = pix[index + across];
        const q2: i32 = pix[index + 2 * across];
        const q3: i32 = pix[index + 3 * across];
        if ((@abs(p0 - q0) << 1) + (@abs(p1 - q1) >> 1) > level) continue;
        if (@abs(p3 - p2) > ilevel or @abs(p2 - p1) > ilevel or @abs(p1 - p0) > ilevel or
            @abs(q1 - q0) > ilevel or @abs(q2 - q1) > ilevel or @abs(q3 - q2) > ilevel) continue;
        if (@abs(p1 - p0) > hlevel or @abs(q1 - q0) > hlevel) {
            // high edge variance: only the 2 pixels at the edge
            const a = 3 * (q0 - p0) + clamp127(p1 - q1);
            pix[index - across] = clip8(p0 + clamp15((a + 3) >> 3));
            pix[index] = clip8(q0 - clamp15((a + 4) >> 3));
        } else if (four_not_six) {
            const a = 3 * (q0 - p0);
            const a1 = clamp15((a + 4) >> 3);
            const a2 = clamp15((a + 3) >> 3);
            const a3 = (a1 + 1) >> 1;
            pix[index - 2 * across] = clip8(p1 + a3);
            pix[index - across] = clip8(p0 + a2);
            pix[index] = clip8(q0 - a1);
            pix[index + across] = clip8(q1 - a3);
        } else {
            const a = clamp127(3 * (q0 - p0) + clamp127(p1 - q1));
            const a1 = (27 * a + 63) >> 7;
            const a2 = (18 * a + 63) >> 7;
            const a3 = (9 * a + 63) >> 7;
            pix[index - 3 * across] = clip8(p2 + a3);
            pix[index - 2 * across] = clip8(p1 + a2);
            pix[index - across] = clip8(p0 + a1);
            pix[index] = clip8(q0 - a1);
            pix[index + across] = clip8(q1 - a2);
            pix[index + 2 * across] = clip8(q2 - a3);
        }
    }
}

fn clip8(x: i32) u8 {
    return @intCast(std.math.clamp(x, 0, 255));
}
fn clamp15(x: i32) i32 {
    return std.math.clamp(x, -16, 15);
}
fn clamp127(x: i32) i32 {
    return std.math.clamp(x, -128, 127);
}

/// Four 0/1 flags <-> bits.
fn pack(x: [4]u8, shift: u5) u32 {
    const u = @as(u32, x[0]) | @as(u32, x[1]) << 1 | @as(u32, x[2]) << 2 | @as(u32, x[3]) << 3;
    return u << shift;
}
fn unpack(bits: u8) [4]u8 {
    return .{ bits & 1, (bits >> 1) & 1, (bits >> 2) & 1, (bits >> 3) & 1 };
}

/// Coefficient position (0..16) -> probability band (13.3).
const bands = [17]u8{ 0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0 };
/// Token order within a 4x4 block.
const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
/// Extra-bit probabilities for DCT_CAT3..DCT_CAT6 (13.2), zero-terminated.
const cat_probs = [4][12]u8{
    .{ 173, 148, 140, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 176, 155, 140, 135, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 180, 157, 141, 134, 130, 0, 0, 0, 0, 0, 0, 0 },
    .{ 254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129, 0 },
};

/// 14.1: quantizer index -> step size.
const dc_table = [128]u16{
    4,   5,   6,   7,   8,   9,   10,  10,  11,  12,  13,  14,  15,  16,  17,  17,
    18,  19,  20,  20,  21,  21,  22,  22,  23,  23,  24,  25,  25,  26,  27,  28,
    29,  30,  31,  32,  33,  34,  35,  36,  37,  37,  38,  39,  40,  41,  42,  43,
    44,  45,  46,  46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,
    59,  60,  61,  62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,
    75,  76,  76,  77,  78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,
    91,  93,  95,  96,  98,  100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
    122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151, 154, 157,
};
const ac_table = [128]u16{
    4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,  17,  18,  19,
    20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,  33,  34,  35,
    36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,  50,  51,
    52,  53,  54,  55,  56,  57,  58,  60,  62,  64,  66,  68,  70,  72,  74,  76,
    78,  80,  82,  84,  86,  88,  90,  92,  94,  96,  98,  100, 102, 104, 106, 108,
    110, 112, 114, 116, 119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152,
    155, 158, 161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
    213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274, 279, 284,
};

test "bool decoder renormalization tables match the reference" {
    // spot checks against golang.org/x/image/vp8 lutShift / lutRangeM1
    try std.testing.expectEqual(@as(u8, 7), BoolDecoder.lut_shift[0]);
    try std.testing.expectEqual(@as(u8, 6), BoolDecoder.lut_shift[1]);
    try std.testing.expectEqual(@as(u8, 1), BoolDecoder.lut_shift[126]);
    try std.testing.expectEqual(@as(u8, 127), BoolDecoder.lut_range_m1[0]);
    try std.testing.expectEqual(@as(u8, 191), BoolDecoder.lut_range_m1[2]);
    try std.testing.expectEqual(@as(u8, 253), BoolDecoder.lut_range_m1[126]);
}
