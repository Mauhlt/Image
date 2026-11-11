//! HEVC parameter sets (H.265 7.3.2) and slice segment headers (7.3.6),
//! parsed as far as intra-only still pictures (HEIC) need.
const std = @import("std");
const Error = @import("../../error.zig").Error;
const BitReader = @import("bits.zig").BitReader;
const NalType = @import("bits.zig").NalType;
const tables = @import("tables.zig");

/// Scaling factors (7.4.5): [sizeId 0..3][matrixId 0..5][coefficient, raster order].
/// 32x32 only uses matrixId 0 and 3 (stored at 0 and 1 for 4:2:0).
pub const ScalingList = struct {
    /// up-sampled factor for each coefficient position, per size (4,8,16,32)
    factors4: [6][16]u8,
    factors8: [6][64]u8,
    factors16: [6][64]u8, // 8x8 base matrix, replicated 2x2 at use
    factors32: [6][64]u8, // 8x8 base matrix, replicated 4x4 at use
    dc16: [6]u8,
    dc32: [6]u8,

    pub const default: ScalingList = blk: {
        var s: ScalingList = undefined;
        for (0..6) |m| {
            s.factors4[m] = @splat(16);
            const base = if (m < 3) tables.default_scaling_intra else tables.default_scaling_inter;
            s.factors8[m] = rasterFromDiag8(base);
            s.factors16[m] = s.factors8[m];
            s.factors32[m] = s.factors8[m];
            s.dc16[m] = 16;
            s.dc32[m] = 16;
        }
        break :blk s;
    };

    /// Factor for coefficient (x, y) of an nTbS block, component matrix `m`.
    pub fn factor(s: *const ScalingList, log2_size: u3, m: usize, x: usize, y: usize) u8 {
        return switch (log2_size) {
            2 => s.factors4[m][y * 4 + x],
            3 => s.factors8[m][y * 8 + x],
            4 => if (x == 0 and y == 0) s.dc16[m] else s.factors16[m][(y >> 1) * 8 + (x >> 1)],
            5 => if (x == 0 and y == 0) s.dc32[m] else s.factors32[m][(y >> 2) * 8 + (x >> 2)],
            else => unreachable,
        };
    }

    /// 7.3.4 scaling_list_data()
    pub fn parse(r: *BitReader) !ScalingList {
        var s: ScalingList = .default;
        for (0..4) |size_id| {
            var m: usize = 0;
            while (m < 6) : (m += if (size_id == 3) 3 else 1) {
                const pred_mode = try r.flag();
                const n_coef: usize = @min(64, @as(usize, 1) << @intCast(4 + (size_id << 1)));
                var list: [64]u8 = undefined;
                var dc: u8 = 16;
                if (!pred_mode) {
                    // copy from a reference list (delta 0 = defaults)
                    const delta = try r.ueMax(@intCast(if (size_id == 3) m / 3 else m));
                    if (delta == 0) {
                        list = if (size_id == 0) @splat(16) else (if (m < 3) tables.default_scaling_intra else tables.default_scaling_inter);
                        dc = 16;
                    } else {
                        const ref = m - delta * (if (size_id == 3) @as(usize, 3) else 1);
                        list = s.diagList(size_id, ref);
                        dc = switch (size_id) {
                            2 => s.dc16[ref],
                            3 => s.dc32[ref],
                            else => 16,
                        };
                    }
                } else {
                    var next: i32 = 8;
                    if (size_id > 1) {
                        const dc_coef = try r.se(); // scaling_list_dc_coef_minus8
                        if (dc_coef < -7 or dc_coef > 247) return Error.InvalidHeader;
                        next = dc_coef + 8;
                        dc = @intCast(next);
                    }
                    for (0..n_coef) |i| {
                        const delta = try r.se();
                        if (delta < -128 or delta > 127) return Error.InvalidHeader;
                        next = @mod(next + delta + 256, 256);
                        list[i] = @intCast(next);
                    }
                }
                s.store(size_id, m, list, dc);
                if (size_id == 3) {
                    // chroma 32x32 lists are not coded; with 4:2:0 they are never used
                    s.store(3, m + 1, list, dc);
                    s.store(3, m + 2, list, dc);
                }
            }
        }
        return s;
    }

    fn diagList(s: *const ScalingList, size_id: usize, m: usize) [64]u8 {
        // inverse of store(): back to up-right diagonal order
        var out: [64]u8 = @splat(16);
        const n: usize = if (size_id == 0) 4 else 8;
        const scan = if (n == 4) &tables.diag4x4 else &tables.diag8x8;
        for (scan, 0..) |pos, i| {
            const x = pos[0];
            const y = pos[1];
            out[i] = switch (size_id) {
                0 => s.factors4[m][y * 4 + x],
                1 => s.factors8[m][y * 8 + x],
                2 => s.factors16[m][y * 8 + x],
                else => s.factors32[m][y * 8 + x],
            };
        }
        return out;
    }

    fn store(s: *ScalingList, size_id: usize, m: usize, diag: [64]u8, dc: u8) void {
        switch (size_id) {
            0 => {
                for (tables.diag4x4, 0..) |pos, i| s.factors4[m][@as(usize, pos[1]) * 4 + pos[0]] = diag[i];
            },
            1 => s.factors8[m] = rasterFromDiag8(diag),
            2 => {
                s.factors16[m] = rasterFromDiag8(diag);
                s.dc16[m] = dc;
            },
            else => {
                s.factors32[m] = rasterFromDiag8(diag);
                s.dc32[m] = dc;
            },
        }
    }

    fn rasterFromDiag8(diag: [64]u8) [64]u8 {
        var out: [64]u8 = undefined;
        for (tables.diag8x8, 0..) |pos, i| out[@as(usize, pos[1]) * 8 + pos[0]] = diag[i];
        return out;
    }
};

pub const Sps = struct {
    id: u32 = 0,
    chroma_format_idc: u2 = 1,
    width: u32 = 0,
    height: u32 = 0,
    /// conformance window, in luma samples
    crop_left: u32 = 0,
    crop_right: u32 = 0,
    crop_top: u32 = 0,
    crop_bottom: u32 = 0,
    bit_depth_luma: u5 = 8,
    bit_depth_chroma: u5 = 8,
    log2_max_poc_lsb: u5 = 4,
    log2_min_cb: u3 = 3,
    log2_ctb: u3 = 4,
    log2_min_tb: u3 = 2,
    log2_max_tb: u3 = 5,
    max_transform_hierarchy_depth_intra: u3 = 0,
    scaling_list_enabled: bool = false,
    scaling_list: ScalingList = .default,
    sao_enabled: bool = false,
    pcm_enabled: bool = false,
    pcm_bit_depth_luma: u5 = 8,
    pcm_bit_depth_chroma: u5 = 8,
    log2_min_pcm: u3 = 3,
    log2_max_pcm: u3 = 3,
    pcm_loop_filter_disabled: bool = false,
    num_short_term_rps: u32 = 0,
    /// number of delta POCs of each short-term RPS (needed to parse later ones)
    rps_num_delta: [65]u32 = @splat(0),
    rps_delta_poc: [65][32]i32 = undefined,
    long_term_refs_present: bool = false,
    num_long_term_ref_pics_sps: u32 = 0,
    temporal_mvp_enabled: bool = false,
    strong_intra_smoothing: bool = false,
    // VUI colour description (ITU-T H.273); used when the HEIF has no colr box
    video_full_range: bool = false,
    colour_primaries: u8 = 2,
    transfer: u8 = 2,
    matrix: u8 = 2,

    pub fn ctbSize(s: Sps) u32 {
        return @as(u32, 1) << s.log2_ctb;
    }
    pub fn widthCtbs(s: Sps) u32 {
        return (s.width + s.ctbSize() - 1) >> s.log2_ctb;
    }
    pub fn heightCtbs(s: Sps) u32 {
        return (s.height + s.ctbSize() - 1) >> s.log2_ctb;
    }
};

fn profileTierLevel(r: *BitReader, max_sub_layers_minus1: u32) !void {
    try r.skip(2 + 1 + 5 + 32 + 4 + 43 + 1 + 8); // general profile, tier, level
    var sub_profile: [8]bool = undefined;
    var sub_level: [8]bool = undefined;
    for (0..max_sub_layers_minus1) |i| {
        sub_profile[i] = try r.flag();
        sub_level[i] = try r.flag();
    }
    if (max_sub_layers_minus1 > 0) try r.skip(2 * (8 - max_sub_layers_minus1));
    for (0..max_sub_layers_minus1) |i| {
        if (sub_profile[i]) try r.skip(88);
        if (sub_level[i]) try r.skip(8);
    }
}

pub fn parseSps(rbsp: []const u8) !Sps {
    var r: BitReader = .{ .data = rbsp };
    var s: Sps = .{};
    try r.skip(4); // vps id
    const max_sub_layers_minus1 = try r.bits(3);
    try r.skip(1); // temporal id nesting
    try profileTierLevel(&r, max_sub_layers_minus1);
    s.id = try r.ueMax(15);
    s.chroma_format_idc = @intCast(try r.ueMax(3));
    if (s.chroma_format_idc == 3 and try r.flag()) return Error.UnsupportedFeature; // separate colour planes
    if (s.chroma_format_idc == 2) return Error.UnsupportedFeature; // 4:2:2 (RExt)
    s.width = try r.ue();
    s.height = try r.ue();
    if (s.width == 0 or s.height == 0 or s.width > 16888 or s.height > 16888) return Error.InvalidDimensions;
    if (try r.flag()) { // conformance window, in chroma sample units
        const sub: u32 = if (s.chroma_format_idc == 1) 2 else 1;
        s.crop_left = sub * try r.ue();
        s.crop_right = sub * try r.ue();
        s.crop_top = sub * try r.ue();
        s.crop_bottom = sub * try r.ue();
        if (s.crop_left + s.crop_right >= s.width or s.crop_top + s.crop_bottom >= s.height) return Error.InvalidDimensions;
    }
    s.bit_depth_luma = @intCast(8 + try r.ueMax(6));
    s.bit_depth_chroma = @intCast(8 + try r.ueMax(6));
    s.log2_max_poc_lsb = @intCast(4 + try r.ueMax(12));
    const ordering_all = try r.flag();
    var i = if (ordering_all) 0 else max_sub_layers_minus1;
    while (i <= max_sub_layers_minus1) : (i += 1) {
        _ = try r.ue();
        _ = try r.ue();
        _ = try r.ue();
    }
    s.log2_min_cb = @intCast(3 + try r.ueMax(3));
    s.log2_ctb = @intCast(@as(u32, s.log2_min_cb) + try r.ueMax(3));
    s.log2_min_tb = @intCast(2 + try r.ueMax(3));
    s.log2_max_tb = @intCast(@as(u32, s.log2_min_tb) + try r.ueMax(3));
    if (s.log2_ctb > 6 or s.log2_ctb < 4 or s.log2_max_tb > @min(5, s.log2_ctb) or s.log2_min_tb >= s.log2_min_cb)
        return Error.InvalidHeader;
    _ = try r.ue(); // max_transform_hierarchy_depth_inter
    s.max_transform_hierarchy_depth_intra = @intCast(try r.ueMax(4));
    s.scaling_list_enabled = try r.flag();
    if (s.scaling_list_enabled and try r.flag()) s.scaling_list = try ScalingList.parse(&r);
    try r.skip(1); // amp
    s.sao_enabled = try r.flag();
    s.pcm_enabled = try r.flag();
    if (s.pcm_enabled) {
        s.pcm_bit_depth_luma = @intCast(1 + try r.bits(4));
        s.pcm_bit_depth_chroma = @intCast(1 + try r.bits(4));
        s.log2_min_pcm = @intCast(3 + try r.ueMax(2));
        s.log2_max_pcm = @intCast(@as(u32, s.log2_min_pcm) + try r.ueMax(2));
        s.pcm_loop_filter_disabled = try r.flag();
    }
    s.num_short_term_rps = try r.ueMax(64);
    for (0..s.num_short_term_rps) |idx| try parseShortTermRps(&r, &s, idx);
    s.long_term_refs_present = try r.flag();
    if (s.long_term_refs_present) {
        s.num_long_term_ref_pics_sps = try r.ueMax(32);
        for (0..s.num_long_term_ref_pics_sps) |_| try r.skip(@as(usize, s.log2_max_poc_lsb) + 1);
    }
    s.temporal_mvp_enabled = try r.flag();
    s.strong_intra_smoothing = try r.flag();
    if (try r.flag()) try parseVui(&r, &s);
    // sps extensions (range extension etc.) are not used by Main / Main 10 / Main Still
    return s;
}

/// 7.3.7 st_ref_pic_set(idx). Only the delta POCs are kept: later sets may be
/// predicted from earlier ones, so they must be tracked even for still images.
pub fn parseShortTermRps(r: *BitReader, s: *Sps, idx: usize) !void {
    if (idx != 0 and try r.flag()) { // inter_ref_pic_set_prediction_flag
        const delta_idx: usize = if (idx == s.num_short_term_rps) 1 + try r.ue() else 1;
        if (delta_idx > idx) return Error.InvalidHeader;
        const ref = idx - delta_idx;
        const sign = try r.flag();
        const abs_delta: i32 = @intCast(1 + try r.ue());
        const delta_rps = if (sign) -abs_delta else abs_delta;
        var n: u32 = 0;
        for (0..s.rps_num_delta[ref] + 1) |j| {
            const used = try r.flag();
            const use_delta = used or try r.flag();
            if (!use_delta) continue;
            const d = delta_rps + (if (j < s.rps_num_delta[ref]) s.rps_delta_poc[ref][j] else 0);
            if (d == 0 or n >= 32) continue;
            s.rps_delta_poc[idx][n] = d;
            n += 1;
        }
        s.rps_num_delta[idx] = n;
        return;
    }
    const neg = try r.ueMax(16);
    const pos = try r.ueMax(16);
    var poc: i32 = 0;
    for (0..neg) |j| {
        poc -= @intCast(1 + try r.ue());
        try r.skip(1);
        s.rps_delta_poc[idx][j] = poc;
    }
    poc = 0;
    for (0..pos) |j| {
        poc += @intCast(1 + try r.ue());
        try r.skip(1);
        s.rps_delta_poc[idx][neg + j] = poc;
    }
    s.rps_num_delta[idx] = neg + pos;
}

/// E.2.1, up to the colour description.
fn parseVui(r: *BitReader, s: *Sps) !void {
    if (try r.flag()) { // aspect ratio
        if (try r.bits(8) == 255) try r.skip(32);
    }
    if (try r.flag()) try r.skip(1); // overscan
    if (try r.flag()) { // video signal type
        try r.skip(3);
        s.video_full_range = try r.flag();
        if (try r.flag()) {
            s.colour_primaries = @intCast(try r.bits(8));
            s.transfer = @intCast(try r.bits(8));
            s.matrix = @intCast(try r.bits(8));
        }
    }
}

pub const Pps = struct {
    id: u32 = 0,
    sps_id: u32 = 0,
    dependent_slices: bool = false,
    output_flag_present: bool = false,
    num_extra_slice_header_bits: u3 = 0,
    sign_data_hiding: bool = false,
    init_qp: i32 = 26,
    transform_skip: bool = false,
    cu_qp_delta_enabled: bool = false,
    diff_cu_qp_delta_depth: u3 = 0,
    cb_qp_offset: i32 = 0,
    cr_qp_offset: i32 = 0,
    slice_chroma_qp_offsets_present: bool = false,
    transquant_bypass_enabled: bool = false,
    tiles_enabled: bool = false,
    entropy_coding_sync: bool = false,
    /// tile boundaries in CTBs: columns[0] = 0 ... columns[n] = width in CTBs
    tile_columns: []u32 = &.{},
    tile_rows: []u32 = &.{},
    loop_filter_across_tiles: bool = true,
    loop_filter_across_slices: bool = false,
    deblocking_override_enabled: bool = false,
    deblocking_disabled: bool = false,
    beta_offset_div2: i32 = 0,
    tc_offset_div2: i32 = 0,
    scaling_list: ?ScalingList = null,
    lists_modification_present: bool = false,
    slice_header_extension_present: bool = false,
};

/// Needs the SPS for tile layout; `arena` holds the tile boundary lists.
pub fn parsePps(arena: std.mem.Allocator, rbsp: []const u8, sps_list: []const Sps) !Pps {
    var r: BitReader = .{ .data = rbsp };
    var p: Pps = .{};
    p.id = try r.ueMax(63);
    p.sps_id = try r.ueMax(15);
    const sps = for (sps_list) |s| {
        if (s.id == p.sps_id) break s;
    } else return Error.InvalidHeader;
    p.dependent_slices = try r.flag();
    p.output_flag_present = try r.flag();
    p.num_extra_slice_header_bits = @intCast(try r.bits(3));
    p.sign_data_hiding = try r.flag();
    try r.skip(1); // cabac_init_present (P/B slices only)
    _ = try r.ue(); // num_ref_idx defaults
    _ = try r.ue();
    p.init_qp = 26 + try r.se();
    try r.skip(1); // constrained intra pred: every block is intra here
    p.transform_skip = try r.flag();
    p.cu_qp_delta_enabled = try r.flag();
    if (p.cu_qp_delta_enabled) p.diff_cu_qp_delta_depth = @intCast(try r.ueMax(3));
    p.cb_qp_offset = try r.se();
    p.cr_qp_offset = try r.se();
    p.slice_chroma_qp_offsets_present = try r.flag();
    try r.skip(2); // weighted prediction
    p.transquant_bypass_enabled = try r.flag();
    p.tiles_enabled = try r.flag();
    p.entropy_coding_sync = try r.flag();
    const w_ctbs = sps.widthCtbs();
    const h_ctbs = sps.heightCtbs();
    if (p.tiles_enabled) {
        const cols = 1 + try r.ueMax(w_ctbs - 1);
        const rows = 1 + try r.ueMax(h_ctbs - 1);
        p.tile_columns = try arena.alloc(u32, cols + 1);
        p.tile_rows = try arena.alloc(u32, rows + 1);
        if (try r.flag()) { // uniform spacing (6-3, 6-4)
            for (0..cols + 1) |i| p.tile_columns[i] = @intCast((i * w_ctbs) / cols);
            for (0..rows + 1) |i| p.tile_rows[i] = @intCast((i * h_ctbs) / rows);
        } else {
            p.tile_columns[0] = 0;
            for (0..cols - 1) |i| p.tile_columns[i + 1] = p.tile_columns[i] + 1 + try r.ue();
            p.tile_columns[cols] = w_ctbs;
            p.tile_rows[0] = 0;
            for (0..rows - 1) |i| p.tile_rows[i + 1] = p.tile_rows[i] + 1 + try r.ue();
            p.tile_rows[rows] = h_ctbs;
            if (p.tile_columns[cols - 1] >= w_ctbs or p.tile_rows[rows - 1] >= h_ctbs) return Error.InvalidHeader;
        }
        p.loop_filter_across_tiles = try r.flag();
    } else {
        p.tile_columns = try arena.dupe(u32, &.{ 0, w_ctbs });
        p.tile_rows = try arena.dupe(u32, &.{ 0, h_ctbs });
    }
    p.loop_filter_across_slices = try r.flag();
    if (try r.flag()) { // deblocking filter control
        p.deblocking_override_enabled = try r.flag();
        p.deblocking_disabled = try r.flag();
        if (!p.deblocking_disabled) {
            p.beta_offset_div2 = try r.se();
            p.tc_offset_div2 = try r.se();
        }
    }
    if (try r.flag()) p.scaling_list = try ScalingList.parse(&r);
    p.lists_modification_present = try r.flag();
    _ = try r.ue(); // log2_parallel_merge_level
    p.slice_header_extension_present = try r.flag();
    return p;
}

pub const SliceHeader = struct {
    first_in_picture: bool,
    dependent: bool = false,
    /// first CTB, in raster scan
    address: u32 = 0,
    pps_id: u32,
    sao_luma: bool = false,
    sao_chroma: bool = false,
    qp: i32 = 26,
    cb_qp_offset: i32 = 0,
    cr_qp_offset: i32 = 0,
    deblocking_disabled: bool = false,
    beta_offset_div2: i32 = 0,
    tc_offset_div2: i32 = 0,
    loop_filter_across_slices: bool = false,
    /// entry points of the substreams after the first, in escaped NAL payload bytes
    /// relative to the start of the slice data
    entry_points: []u32 = &.{},
    /// bit offset of the slice data in the rbsp
    data_offset: usize = 0,
};

/// `prev` is the previous independent slice segment of the picture (for dependent ones).
pub fn parseSliceHeader(arena: std.mem.Allocator, rbsp: []const u8, nal_type: NalType, sps: *const Sps, pps_list: []const Pps, prev: ?*const SliceHeader) !SliceHeader {
    var r: BitReader = .{ .data = rbsp };
    var h: SliceHeader = .{ .first_in_picture = try r.flag(), .pps_id = 0 };
    const irap = @intFromEnum(nal_type) >= 16 and @intFromEnum(nal_type) <= 23;
    if (!irap) return Error.UnsupportedFeature; // HEIC images are intra random access points
    try r.skip(1); // no_output_of_prior_pics
    h.pps_id = try r.ueMax(63);
    const pps = for (pps_list) |*p| {
        if (p.id == h.pps_id) break p;
    } else return Error.InvalidHeader;
    if (!h.first_in_picture) {
        if (pps.dependent_slices) h.dependent = try r.flag();
        const n_ctbs = sps.widthCtbs() * sps.heightCtbs();
        h.address = try r.bits(@intCast(std.math.log2_int_ceil(u32, n_ctbs)));
        if (h.address >= n_ctbs) return Error.InvalidHeader;
    }
    if (h.dependent) {
        const p = prev orelse return Error.InvalidHeader;
        const address = h.address;
        h = p.*;
        h.first_in_picture = false;
        h.dependent = true;
        h.address = address;
        h.entry_points = &.{};
    } else {
        try r.skip(pps.num_extra_slice_header_bits);
        const slice_type = try r.ue();
        if (slice_type != 2) return Error.UnsupportedFeature; // P / B slices: video only
        if (pps.output_flag_present) try r.skip(1);
        if (@intFromEnum(nal_type) != 19 and @intFromEnum(nal_type) != 20) { // not IDR: POC + RPS
            try r.skip(sps.log2_max_poc_lsb);
            if (!try r.flag()) {
                var copy = sps.*;
                try parseShortTermRps(&r, &copy, sps.num_short_term_rps);
            } else if (sps.num_short_term_rps > 1) {
                try r.skip(std.math.log2_int_ceil(u32, sps.num_short_term_rps));
            }
            if (sps.long_term_refs_present) {
                const n_sps: u32 = if (sps.num_long_term_ref_pics_sps > 0) try r.ue() else 0;
                const n_pics = try r.ue();
                for (0..n_sps + n_pics) |j| {
                    if (j < n_sps) {
                        if (sps.num_long_term_ref_pics_sps > 1) try r.skip(std.math.log2_int_ceil(u32, sps.num_long_term_ref_pics_sps));
                    } else {
                        try r.skip(@as(usize, sps.log2_max_poc_lsb) + 1);
                    }
                    if (try r.flag()) _ = try r.ue();
                }
            }
            if (sps.temporal_mvp_enabled) try r.skip(1);
        }
        if (sps.sao_enabled) {
            h.sao_luma = try r.flag();
            if (sps.chroma_format_idc != 0) h.sao_chroma = try r.flag();
        }
        h.qp = pps.init_qp + try r.se();
        if (pps.slice_chroma_qp_offsets_present) {
            h.cb_qp_offset = try r.se();
            h.cr_qp_offset = try r.se();
        }
        h.deblocking_disabled = pps.deblocking_disabled;
        h.beta_offset_div2 = pps.beta_offset_div2;
        h.tc_offset_div2 = pps.tc_offset_div2;
        if (pps.deblocking_override_enabled and try r.flag()) {
            h.deblocking_disabled = try r.flag();
            if (!h.deblocking_disabled) {
                h.beta_offset_div2 = try r.se();
                h.tc_offset_div2 = try r.se();
            }
        }
        h.loop_filter_across_slices = pps.loop_filter_across_slices;
        if (pps.loop_filter_across_slices and (h.sao_luma or h.sao_chroma or !h.deblocking_disabled))
            h.loop_filter_across_slices = try r.flag();
    }
    if (pps.tiles_enabled or pps.entropy_coding_sync) {
        const n = try r.ueMax(1 << 16);
        if (n > 0) {
            const len: u6 = @intCast(1 + try r.ueMax(31));
            h.entry_points = try arena.alloc(u32, n);
            var acc: u32 = 0;
            for (h.entry_points) |*e| {
                acc += 1 + try r.bits(len);
                e.* = acc;
            }
        }
    }
    if (pps.slice_header_extension_present) try r.skip(8 * @as(usize, try r.ueMax(256)));
    // byte_alignment(): a 1 then zeros
    if (try r.bit() != 1) return Error.InvalidHeader;
    r.alignToByte();
    h.data_offset = r.pos;
    return h;
}

test "parse parameter sets and slice headers of the HEIC samples" {
    const heif = @import("../heif.zig");
    const bits = @import("bits.zig");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_][]const u8{ "src/Data/Read/heic/C002.heic", "src/Data/Read/heic/C014.heic", "src/Data/Read/heic/C021.heic" }) |path| {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
        const img = try heif.parse(arena, data);
        for (img.tiles) |tile| {
            var sps_list: std.ArrayList(Sps) = .empty;
            var pps_list: std.ArrayList(Pps) = .empty;
            for (tile.param_sets) |ps| {
                const nal = try bits.parseNal(arena, ps);
                switch (nal.type) {
                    .sps => try sps_list.append(arena, try parseSps(nal.rbsp)),
                    .pps => try pps_list.append(arena, try parsePps(arena, nal.rbsp, sps_list.items)),
                    else => {},
                }
            }
            const sps = &sps_list.items[0];
            try std.testing.expectEqual(tile.width, sps.width - sps.crop_left - sps.crop_right);
            // walk the length-prefixed slice NAL units
            var pos: usize = 0;
            var slices: usize = 0;
            while (pos + tile.length_size <= tile.data.len) {
                var len: usize = 0;
                for (tile.data[pos..][0..tile.length_size]) |b| len = (len << 8) | b;
                pos += tile.length_size;
                const nal = try bits.parseNal(arena, tile.data[pos..][0..len]);
                pos += len;
                if (!nal.type.isSlice()) continue;
                const h = try parseSliceHeader(arena, nal.rbsp, nal.type, sps, pps_list.items, null);
                try std.testing.expect(h.data_offset > 0 and h.data_offset / 8 < nal.rbsp.len);
                slices += 1;
            }
            try std.testing.expect(slices >= 1);
        }
    }
}
