//! Slice segment data (H.265 7.3.8): parses each coding tree unit and
//! reconstructs it (intra prediction + residual) as it goes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Error = @import("../../error.zig").Error;
const bits = @import("bits.zig");
const cabac = @import("cabac.zig");
const params = @import("params.zig");
const tables = @import("tables.zig");
const intra = @import("intra.zig");
const residual = @import("residual.zig");
const Picture = @import("picture.zig").Picture;

/// Context state that carries across slice segments of a picture.
pub const Carry = struct {
    /// stored at the end of a slice segment, for a following dependent one (9.3.2.4)
    dependent: ?cabac.Contexts = null,
    /// qPY_PREV carries into a dependent slice segment (8.6.1 resets it per slice)
    qp_prev: i32 = 0,
};

pub fn decode(pic: *Picture, slice_index: u16, nal: bits.Nal, carry: *Carry) !void {
    var s: Slice = .{
        .pic = pic,
        .sps = pic.sps,
        .pps = pic.pps,
        .hdr = &pic.slices.items[slice_index],
        .index = slice_index,
        .nal = nal,
        .d = undefined,
        .ctx = undefined,
    };
    try s.run(carry);
}

const Slice = struct {
    pic: *Picture,
    sps: *const params.Sps,
    pps: *const params.Pps,
    hdr: *const params.SliceHeader,
    index: u16,
    nal: bits.Nal,
    d: cabac.Decoder,
    ctx: cabac.Contexts,
    /// contexts after the second CTB of the previous CTB row (WPP, 9.3.2.3)
    wpp: ?cabac.Contexts = null,

    // quantization (8.6.1)
    qp_y_prev: i32 = 0,
    qp_y_pred: i32 = 0,
    qp_y: i32 = 0,
    cu_qp_delta: i32 = 0,
    cu_qp_delta_coded: bool = false,

    // current coding unit
    cu_x: usize = 0,
    cu_y: usize = 0,
    cu_size: usize = 0,
    bypass: bool = false,
    chroma_mode: u8 = 0,

    coeffs: [32 * 32]i32 = undefined,

    fn run(s: *Slice, carry: *Carry) !void {
        const pic = s.pic;
        const sps = s.sps;
        const w_ctbs = sps.widthCtbs();
        const n_ctbs = w_ctbs * sps.heightCtbs();

        // substream start offsets in the rbsp (entry points count emulation prevention bytes)
        const data_start = s.hdr.data_offset / 8;
        const escaped_start = escapedOffset(s.nal, data_start);
        var substream: usize = 0;
        s.d = .init(s.nal.rbsp, data_start);

        var ts: usize = pic.rs_to_ts[s.hdr.address];
        var first = true;
        while (true) {
            const rs = pic.ts_to_rs[ts];
            const x = rs % w_ctbs;
            const y = rs / w_ctbs;
            if (first or s.startsSubstream(rs)) {
                if (!first) {
                    if (s.d.terminate() != 1) return Error.InvalidHeader; // end_of_subset_one_bit
                    substream += 1;
                    if (substream > s.hdr.entry_points.len) return Error.InvalidHeader;
                    const start = s.nal.rbspOffset(escaped_start + s.hdr.entry_points[substream - 1]);
                    if (start >= s.nal.rbsp.len) return Error.UnexpectedEndOfData;
                    s.d = .init(s.nal.rbsp, start);
                }
                s.initContexts(rs, first, carry);
            }
            if (s.resetsQpPrediction(rs) or (first and !s.hdr.dependent)) {
                s.qp_y_prev = s.hdr.qp;
            } else if (first) {
                s.qp_y_prev = carry.qp_prev;
            }
            first = false;

            try s.ctu(x, y);
            const end = s.d.terminate() == 1; // end_of_slice_segment_flag
            if (s.pps.entropy_coding_sync and x == s.tileColumnStart(x) + 1) s.wpp = s.ctx;
            ts += 1;
            if (end) {
                if (s.pps.dependent_slices) {
                    carry.dependent = s.ctx;
                    carry.qp_prev = s.qp_y_prev;
                }
                return;
            }
            if (ts >= n_ctbs) return Error.UnexpectedEndOfData;
        }
    }

    /// Maps an rbsp byte offset back to the escaped NAL payload.
    fn escapedOffset(nal: bits.Nal, rbsp_pos: usize) usize {
        var e = rbsp_pos;
        for (nal.removed) |p| {
            if (p <= e) e += 1 else break;
        }
        return e;
    }

    fn tileColumnStart(s: *const Slice, x: usize) usize {
        var start: usize = 0;
        for (s.pps.tile_columns) |c| {
            if (c <= x) start = c else break;
        }
        return start;
    }
    fn tileRowStart(s: *const Slice, y: usize) usize {
        var start: usize = 0;
        for (s.pps.tile_rows) |r| {
            if (r <= y) start = r else break;
        }
        return start;
    }

    /// A new tile, or (with WPP) a new CTB row within a tile, starts a substream.
    fn startsSubstream(s: *const Slice, rs: usize) bool {
        const w = s.sps.widthCtbs();
        const x = rs % w;
        const y = rs / w;
        if (x == s.tileColumnStart(x) and y == s.tileRowStart(y)) return true;
        return s.pps.entropy_coding_sync and x == s.tileColumnStart(x);
    }

    /// 8.6.1: qPY_PREV restarts at SliceQpY for the first QG of a slice, a
    /// tile, or (with WPP) a CTB row.
    fn resetsQpPrediction(s: *const Slice, rs: usize) bool {
        return s.startsSubstream(rs);
    }

    /// 9.3.1: contexts at the start of a CTU that begins a substream / slice segment.
    fn initContexts(s: *Slice, rs: usize, slice_start: bool, carry: *Carry) void {
        const w = s.sps.widthCtbs();
        const x = rs % w;
        const y = rs / w;
        const tile_start = x == s.tileColumnStart(x) and y == s.tileRowStart(y);
        if (tile_start) {
            s.ctx = .init(s.hdr.qp);
        } else if (s.pps.entropy_coding_sync and x == s.tileColumnStart(x)) {
            // sync from the CTB above-right if it is available
            const size = s.sps.ctbSize();
            s.fillCtbSlice(x, y);
            const cx = x * size;
            const cy = y * size;
            const tr_ok = y > 0 and s.pic.available(cx, cy, @intCast(cx + size), @as(isize, @intCast(cy)) - 1);
            s.ctx = if (tr_ok and s.wpp != null) s.wpp.? else .init(s.hdr.qp);
        } else if (slice_start and s.hdr.dependent and carry.dependent != null) {
            s.ctx = carry.dependent.?;
        } else if (slice_start) {
            s.ctx = .init(s.hdr.qp);
        }
    }

    fn fillCtbSlice(s: *Slice, x: usize, y: usize) void {
        const size = s.sps.ctbSize();
        s.pic.fillBlocks(x * size, y * size, size, size, "slice", s.index);
    }

    // ───────────────────────────── CTU / SAO ─────────────────────────────

    fn ctu(s: *Slice, x_ctb: usize, y_ctb: usize) !void {
        s.fillCtbSlice(x_ctb, y_ctb);
        if (s.hdr.sao_luma or s.hdr.sao_chroma) s.sao(x_ctb, y_ctb);
        try s.codingQuadtree(x_ctb << s.sps.log2_ctb, y_ctb << s.sps.log2_ctb, s.sps.log2_ctb, 0);
    }

    /// 7.3.8.3
    fn sao(s: *Slice, rx: usize, ry: usize) void {
        const pic = s.pic;
        const w = s.sps.widthCtbs();
        const rs = ry * w + rx;
        const size = s.sps.ctbSize();
        const here = &pic.sao[rs];
        const cx = rx * size;
        const cy = ry * size;
        if (rx > 0 and s.sameSliceAndTile(cx, cy, cx - size, cy) and s.d.decision(&s.ctx.sao_merge[0]) == 1) {
            here.* = pic.sao[rs - 1];
            return;
        }
        if (ry > 0 and s.sameSliceAndTile(cx, cy, cx, cy - size) and s.d.decision(&s.ctx.sao_merge[0]) == 1) {
            here.* = pic.sao[rs - w];
            return;
        }
        const n_comp: usize = if (s.sps.chroma_format_idc == 0) 1 else 3;
        for (0..n_comp) |c| {
            here.type[c] = 0;
            if ((c == 0 and !s.hdr.sao_luma) or (c > 0 and !s.hdr.sao_chroma)) continue;
            if (c == 2) {
                here.type[2] = here.type[1];
                here.eo_class[2] = here.eo_class[1];
            } else {
                // sao_type_idx: TR, first bin coded, second bypass
                here.type[c] = if (s.d.decision(&s.ctx.sao_type[0]) == 0) 0 else if (s.d.bypass() == 0) 1 else 2;
            }
            if (here.type[c] == 0) continue;
            const bit_depth = if (c == 0) s.sps.bit_depth_luma else s.sps.bit_depth_chroma;
            const shift: u4 = @intCast(@min(bit_depth, 10) - 5);
            const max: u32 = (@as(u32, 1) << shift) - 1; // = (1 << (min(bitDepth,10) - 5)) - 1
            var abs: [4]i16 = undefined;
            for (&abs) |*a| {
                var v: u32 = 0;
                while (v < max and s.d.bypass() == 1) v += 1;
                a.* = @intCast(v);
            }
            if (here.type[c] == 1) { // band offset: explicit signs and a start band
                for (&abs) |*a| if (a.* != 0 and s.d.bypass() == 1) {
                    a.* = -a.*;
                };
                here.band_position[c] = @intCast(s.d.bypassBits(5));
            } else { // edge offset: fixed signs (+, +, -, -)
                abs[2] = -abs[2];
                abs[3] = -abs[3];
                if (c < 2) here.eo_class[c] = @intCast(s.d.bypassBits(2));
            }
            here.offset[c] = abs; // log2_sao_offset_scale is 0 outside the range extensions
        }
    }

    fn sameSliceAndTile(s: *const Slice, x: usize, y: usize, xn: usize, yn: usize) bool {
        const pic = s.pic;
        if (pic.sliceStart(pic.block(xn, yn).slice) != pic.sliceStart(pic.block(x, y).slice)) return false;
        return pic.tile_id[pic.ctbAddr(xn, yn)] == pic.tile_id[pic.ctbAddr(x, y)];
    }

    // ───────────────────────────── Coding tree ─────────────────────────────

    fn codingQuadtree(s: *Slice, x0: usize, y0: usize, log2: u3, depth: u8) !void {
        const size = @as(usize, 1) << log2;
        const w = s.sps.width;
        const h = s.sps.height;
        var split = log2 > s.sps.log2_min_cb;
        if (x0 + size <= w and y0 + size <= h and log2 > s.sps.log2_min_cb) {
            // context: neighbours left / above that are deeper than this level
            var inc: usize = 0;
            if (s.pic.available(x0, y0, @as(isize, @intCast(x0)) - 1, @intCast(y0)) and s.pic.block(x0 - 1, y0).ct_depth > depth) inc += 1;
            if (s.pic.available(x0, y0, @intCast(x0), @as(isize, @intCast(y0)) - 1) and s.pic.block(x0, y0 - 1).ct_depth > depth) inc += 1;
            split = s.d.decision(&s.ctx.split_cu[inc]) == 1;
        }
        const log2_qg = s.sps.log2_ctb - s.pps.diff_cu_qp_delta_depth;
        if (log2 >= log2_qg) s.startQuantGroup(x0, y0);
        if (split) {
            const half = size / 2;
            for ([_][2]usize{ .{ 0, 0 }, .{ half, 0 }, .{ 0, half }, .{ half, half } }) |o| {
                if (x0 + o[0] < w and y0 + o[1] < h) try s.codingQuadtree(x0 + o[0], y0 + o[1], log2 - 1, depth + 1);
            }
        } else {
            try s.codingUnit(x0, y0, log2, depth);
        }
    }

    /// 8.6.1: luma QP prediction for a quantization group.
    fn startQuantGroup(s: *Slice, x: usize, y: usize) void {
        s.cu_qp_delta = 0;
        s.cu_qp_delta_coded = false;
        const ctb = s.pic.ctbAddr(x, y);
        const prev = s.qp_y_prev;
        var a = prev;
        var b = prev;
        if (s.pic.available(x, y, @as(isize, @intCast(x)) - 1, @intCast(y)) and s.pic.ctbAddr(x - 1, y) == ctb) a = s.pic.block(x - 1, y).qp_y;
        if (s.pic.available(x, y, @intCast(x), @as(isize, @intCast(y)) - 1) and s.pic.ctbAddr(x, y - 1) == ctb) b = s.pic.block(x, y - 1).qp_y;
        s.qp_y_pred = (a + b + 1) >> 1;
    }

    fn updateQp(s: *Slice) void {
        const off: i32 = 6 * (@as(i32, s.sps.bit_depth_luma) - 8);
        s.qp_y = @mod(s.qp_y_pred + s.cu_qp_delta + 52 + 2 * off, 52 + off) - off;
    }

    fn codingUnit(s: *Slice, x0: usize, y0: usize, log2: u3, depth: u8) !void {
        const size = @as(usize, 1) << log2;
        const pic = s.pic;
        s.cu_x = x0;
        s.cu_y = y0;
        s.cu_size = size;
        s.bypass = s.pps.transquant_bypass_enabled and s.d.decision(&s.ctx.transquant_bypass[0]) == 1;
        s.updateQp();
        pic.fillBlocks(x0, y0, size, size, "ct_depth", depth);

        const nxn = log2 == s.sps.log2_min_cb and s.d.decision(&s.ctx.part_mode[0]) == 0;
        var pcm = false;
        if (!nxn and s.sps.pcm_enabled and log2 >= s.sps.log2_min_pcm and log2 <= s.sps.log2_max_pcm)
            pcm = s.d.terminate() == 1;

        if (pcm) {
            pic.fillBlocks(x0, y0, size, size, "intra_mode", intra.dc);
            try s.pcmSamples(x0, y0, log2);
            if (s.sps.pcm_loop_filter_disabled) pic.fillBlocks(x0, y0, size, size, "no_filter", true);
        } else {
            // luma modes: all prev_intra_luma_pred_flags first, then the indices
            const n_pu: usize = if (nxn) 4 else 1;
            const pu: usize = if (nxn) size / 2 else size;
            var prev: [4]bool = undefined;
            for (prev[0..n_pu]) |*p| p.* = s.d.decision(&s.ctx.prev_intra_luma_pred[0]) == 1;
            for (0..n_pu) |i| {
                const px = x0 + (i & 1) * pu;
                const py = y0 + (i >> 1) * pu;
                var mpm: u2 = 0;
                var rem: u8 = 0;
                if (prev[i]) {
                    mpm = if (s.d.bypass() == 0) 0 else 1 + @as(u2, s.d.bypass());
                } else {
                    rem = @intCast(s.d.bypassBits(5));
                }
                const mode = s.lumaMode(px, py, prev[i], mpm, rem);
                pic.fillBlocks(px, py, pu, pu, "intra_mode", mode);
            }
            if (s.sps.chroma_format_idc != 0) {
                const code: u8 = if (s.d.decision(&s.ctx.intra_chroma_pred_mode[0]) == 0) 4 else @intCast(s.d.bypassBits(2));
                s.chroma_mode = chromaMode(code, pic.block(x0, y0).intra_mode);
            }
            const max_depth = @as(u8, s.sps.max_transform_hierarchy_depth_intra) + @intFromBool(nxn);
            try s.transformTree(x0, y0, x0, y0, log2, 0, 0, max_depth, nxn, true, true);
        }
        if (s.bypass) pic.fillBlocks(x0, y0, size, size, "no_filter", true);
        pic.fillBlocks(x0, y0, size, size, "qp_y", @as(i8, @intCast(s.qp_y)));
        pic.fillBlocks(x0, y0, size, size, "decoded", true);
        s.qp_y_prev = s.qp_y;
    }

    /// 8.4.2: most probable modes from the left (A) and above (B) neighbours.
    fn lumaMode(s: *const Slice, x: usize, y: usize, prev: bool, mpm: u2, rem: u8) u8 {
        const a = s.neighbourMode(x, y, @as(isize, @intCast(x)) - 1, @intCast(y));
        // B must lie in the same CTB row
        const ctb_top = (y >> s.sps.log2_ctb) << s.sps.log2_ctb;
        const b = if (y == ctb_top) intra.dc else s.neighbourMode(x, y, @intCast(x), @as(isize, @intCast(y)) - 1);
        var cand: [3]u8 = undefined;
        if (a == b) {
            cand = if (a < 2) .{ intra.planar, intra.dc, 26 } else .{ a, 2 + ((a + 29) % 32), 2 + ((a - 2 + 1) % 32) };
        } else {
            const c: u8 = if (a != intra.planar and b != intra.planar) intra.planar else if (a != intra.dc and b != intra.dc) intra.dc else 26;
            cand = .{ a, b, c };
        }
        if (prev) return cand[mpm];
        std.mem.sort(u8, &cand, {}, std.sort.asc(u8));
        var mode = rem;
        for (cand) |c| {
            if (mode >= c) mode += 1;
        }
        return mode;
    }

    /// The neighbour's luma mode, or DC if it isn't available. Blocks earlier in
    /// the current CU (NxN) count as available: they precede it in z-scan order
    /// even though they aren't reconstructed yet.
    fn neighbourMode(s: *const Slice, x: usize, y: usize, xn: isize, yn: isize) u8 {
        if (xn < 0 or yn < 0) return intra.dc;
        const nx: usize = @intCast(xn);
        const ny: usize = @intCast(yn);
        const inside_cu = nx >= s.cu_x and ny >= s.cu_y and nx < s.cu_x + s.cu_size and ny < s.cu_y + s.cu_size;
        if (!inside_cu and !s.pic.available(x, y, xn, yn)) return intra.dc;
        return s.pic.block(nx, ny).intra_mode;
    }

    /// 8.4.3 (4:2:0): intra_chroma_pred_mode -> mode; 34 replaces a duplicate of the luma mode.
    fn chromaMode(code: u8, luma: u8) u8 {
        const m: u8 = switch (code) {
            0 => intra.planar,
            1 => 26,
            2 => 10,
            3 => intra.dc,
            else => return luma,
        };
        return if (m == luma) 34 else m;
    }

    fn transformTree(s: *Slice, x0: usize, y0: usize, x_base: usize, y_base: usize, log2: u3, depth: u8, blk: u2, max_depth: u8, intra_split: bool, parent_cb: bool, parent_cr: bool) !void {
        const sps = s.sps;
        var split: bool = undefined;
        if (log2 <= sps.log2_max_tb and log2 > sps.log2_min_tb and depth < max_depth and !(intra_split and depth == 0)) {
            split = s.d.decision(&s.ctx.split_transform[5 - @as(usize, log2)]) == 1;
        } else {
            split = log2 > sps.log2_max_tb or (intra_split and depth == 0);
        }
        // chroma cbfs: coded down to 8x8 luma; 4x4 luma blocks use their parent's
        var cb = parent_cb;
        var cr = parent_cr;
        if (sps.chroma_format_idc != 0 and log2 > 2) {
            cb = (depth == 0 or parent_cb) and s.d.decision(&s.ctx.cbf_chroma[depth]) == 1;
            cr = (depth == 0 or parent_cr) and s.d.decision(&s.ctx.cbf_chroma[depth]) == 1;
        } else if (sps.chroma_format_idc == 0) {
            cb = false;
            cr = false;
        }
        if (split) {
            const half = @as(usize, 1) << (log2 - 1);
            for (0..4) |i| {
                const x = x0 + (i & 1) * half;
                const y = y0 + (i >> 1) * half;
                try s.transformTree(x, y, x0, y0, log2 - 1, depth + 1, @intCast(i), max_depth, intra_split, cb, cr);
            }
            return;
        }
        const cbf_luma = s.d.decision(&s.ctx.cbf_luma[@intFromBool(depth == 0)]) == 1;
        try s.transformUnit(x0, y0, x_base, y_base, log2, blk, cbf_luma, cb, cr);
    }

    fn transformUnit(s: *Slice, x0: usize, y0: usize, x_base: usize, y_base: usize, log2: u3, blk: u2, cbf_luma: bool, cbf_cb: bool, cbf_cr: bool) !void {
        const pic = s.pic;
        const size = @as(usize, 1) << log2;
        if ((cbf_luma or cbf_cb or cbf_cr) and s.pps.cu_qp_delta_enabled and !s.cu_qp_delta_coded) {
            // cu_qp_delta_abs: TU prefix (first bin ctx 0, others ctx 1), EG0 suffix
            var v: i32 = 0;
            while (v < 5 and s.d.decision(&s.ctx.cu_qp_delta_abs[@intFromBool(v > 0)]) == 1) v += 1;
            if (v == 5) v += @intCast(s.expGolomb(0));
            if (v > 0 and s.d.bypass() == 1) v = -v;
            s.cu_qp_delta = v;
            s.cu_qp_delta_coded = true;
            s.updateQp();
        }

        // luma: predict, then add the residual
        const luma_mode = pic.block(x0, y0).intra_mode;
        intra.predict(pic, 0, x0, y0, log2, luma_mode);
        if (cbf_luma) s.addResidual(0, x0, y0, log2, luma_mode);
        pic.fillBlocks(x0, y0, size, size, "decoded", true);
        // transform edges for the deblocking filter
        pic.fillBlocks(x0, y0, 4, size, "edge_left", true);
        pic.fillBlocks(x0, y0, size, 4, "edge_top", true);

        if (s.sps.chroma_format_idc == 0) return;
        // 4:2:0: chroma blocks are half size; four 4x4 luma blocks share one 4x4 chroma block
        var cx: usize = x0 >> 1;
        var cy: usize = y0 >> 1;
        var clog2: u3 = log2 - 1;
        if (log2 == 2) {
            if (blk != 3) return;
            cx = x_base >> 1;
            cy = y_base >> 1;
            clog2 = 2;
        }
        for ([_]u2{ 1, 2 }, [_]bool{ cbf_cb, cbf_cr }) |c, cbf| {
            intra.predict(pic, c, cx, cy, clog2, s.chroma_mode);
            if (cbf) s.addResidual(c, cx, cy, clog2, s.chroma_mode);
        }
    }

    fn expGolomb(s: *Slice, k0: u5) u32 {
        var k = k0;
        var v: u32 = 0;
        while (k < 31 and s.d.bypass() == 1) {
            v += @as(u32, 1) << k;
            k += 1;
        }
        return v + s.d.bypassBits(k);
    }

    /// Parses, scales and inverse-transforms one block's residual and adds it
    /// to the prediction already in the plane.
    fn addResidual(s: *Slice, c: u2, x0: usize, y0: usize, log2: u3, mode: u8) void {
        const sps = s.sps;
        const n = @as(usize, 1) << log2;
        const coeffs = s.coeffs[0 .. n * n];
        @memset(coeffs, 0);
        const ts = residual.parse(&s.d, &s.ctx, .{
            .log2 = log2,
            .c = c,
            .pred_mode = mode,
            .transform_skip_enabled = s.pps.transform_skip,
            .sign_data_hiding = s.pps.sign_data_hiding,
            .bypass = s.bypass,
        }, coeffs);
        const bit_depth = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
        if (!s.bypass) {
            const qp = s.componentQp(c);
            const scaling: ?*const params.ScalingList = if (!sps.scaling_list_enabled or (ts and n > 4))
                null
            else if (s.pps.scaling_list) |*l| l else &sps.scaling_list;
            residual.dequantize(coeffs, log2, qp, bit_depth, scaling, c);
            residual.inverseTransform(coeffs, log2, bit_depth, c == 0 and log2 == 2, ts);
        }
        const plane = s.pic.planes[c];
        const stride = s.pic.width[c];
        const max: i32 = (@as(i32, 1) << @intCast(bit_depth)) - 1;
        for (0..n) |y| for (0..n) |x| {
            const i = (y0 + y) * stride + x0 + x;
            plane[i] = @intCast(std.math.clamp(@as(i32, plane[i]) + coeffs[y * n + x], 0, max));
        };
    }

    /// Qp' (with the bit-depth offset) for component c (8.6.1).
    fn componentQp(s: *const Slice, c: u2) i32 {
        if (c == 0) return s.qp_y + 6 * (@as(i32, s.sps.bit_depth_luma) - 8);
        const off_c = 6 * (@as(i32, s.sps.bit_depth_chroma) - 8);
        const offset = if (c == 1) s.pps.cb_qp_offset + s.hdr.cb_qp_offset else s.pps.cr_qp_offset + s.hdr.cr_qp_offset;
        const qpi = std.math.clamp(s.qp_y + offset, -off_c, 57);
        return tables.chromaQp(qpi) + off_c;
    }

    /// 7.3.8.7: raw PCM samples, byte-aligned after the pcm_flag.
    fn pcmSamples(s: *Slice, x0: usize, y0: usize, log2: u3) !void {
        const sps = s.sps;
        var r: bits.BitReader = .{ .data = s.nal.rbsp, .pos = s.d.bytePosAfterTerminate() * 8 };
        const size = @as(usize, 1) << log2;
        try s.readPcm(&r, 0, x0, y0, size, sps.pcm_bit_depth_luma, sps.bit_depth_luma);
        if (sps.chroma_format_idc != 0) {
            for ([_]usize{ 1, 2 }) |c| try s.readPcm(&r, c, x0 >> 1, y0 >> 1, size >> 1, sps.pcm_bit_depth_chroma, sps.bit_depth_chroma);
        }
        // 9.3.2.5: the arithmetic decoder restarts after the samples (contexts are kept)
        s.d = .init(s.nal.rbsp, r.pos / 8);
    }

    fn readPcm(s: *Slice, r: *bits.BitReader, c: usize, x0: usize, y0: usize, n: usize, pcm_depth: u5, bit_depth: u5) !void {
        const plane = s.pic.planes[c];
        const stride = s.pic.width[c];
        for (0..n) |y| for (0..n) |x| {
            const v = try r.bits(pcm_depth);
            plane[(y0 + y) * stride + x0 + x] = @intCast(v << @intCast(bit_depth - pcm_depth));
        };
    }
};
