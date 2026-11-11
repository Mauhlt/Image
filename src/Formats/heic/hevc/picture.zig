//! A decoded HEVC picture: sample planes plus the per-block metadata that
//! prediction, deblocking and SAO need.
const std = @import("std");
const Allocator = std.mem.Allocator;
const params = @import("params.zig");

/// Per 4x4 luma block (the minimum transform size).
pub const BlockInfo = struct {
    decoded: bool = false,
    /// samples left as decoded by the in-loop filters (PCM with loop filter
    /// disabled, or cu_transquant_bypass)
    no_filter: bool = false,
    /// a transform/prediction block edge runs along the left / top side
    edge_left: bool = false,
    edge_top: bool = false,
    intra_mode: u8 = 1, // DC
    qp_y: i8 = 0,
    ct_depth: u8 = 0,
    /// index into Picture.slices
    slice: u16 = 0,
};

/// Sample adaptive offset parameters of one CTB (7.4.9.3).
pub const Sao = struct {
    /// 0 = off, 1 = band offset, 2 = edge offset; per component
    type: [3]u2 = @splat(0),
    offset: [3][4]i16 = @splat(@splat(0)),
    band_position: [3]u5 = @splat(0),
    eo_class: [3]u2 = @splat(0),
};

pub const Picture = struct {
    sps: *const params.Sps,
    pps: *const params.Pps,
    /// Y, Cb, Cr (Cb / Cr empty for monochrome)
    planes: [3][]u16,
    width: [3]usize,
    height: [3]usize,
    chroma_shift: u1, // 1 for 4:2:0
    w4: usize,
    h4: usize,
    blocks: []BlockInfo,
    /// per CTB (raster)
    sao: []Sao,
    tile_id: []u16,
    /// CTB address conversions (6.5.1)
    rs_to_ts: []u32,
    ts_to_rs: []u32,
    slices: std.ArrayList(params.SliceHeader) = .empty,

    pub fn init(arena: Allocator, sps: *const params.Sps, pps: *const params.Pps) !Picture {
        const mono = sps.chroma_format_idc == 0;
        const shift: u1 = if (sps.chroma_format_idc == 1) 1 else 0;
        var p: Picture = .{
            .sps = sps,
            .pps = pps,
            .planes = undefined,
            .width = .{ sps.width, if (mono) 0 else sps.width >> shift, if (mono) 0 else sps.width >> shift },
            .height = .{ sps.height, if (mono) 0 else sps.height >> shift, if (mono) 0 else sps.height >> shift },
            .chroma_shift = shift,
            .w4 = (sps.width + 3) / 4,
            .h4 = (sps.height + 3) / 4,
            .blocks = undefined,
            .sao = undefined,
            .tile_id = undefined,
            .rs_to_ts = undefined,
            .ts_to_rs = undefined,
        };
        for (0..3) |c| p.planes[c] = try arena.alloc(u16, p.width[c] * p.height[c]);
        p.blocks = try arena.alloc(BlockInfo, p.w4 * p.h4);
        @memset(p.blocks, .{});
        const w_ctbs = sps.widthCtbs();
        const n_ctbs = w_ctbs * sps.heightCtbs();
        p.sao = try arena.alloc(Sao, n_ctbs);
        @memset(p.sao, .{});
        p.tile_id = try arena.alloc(u16, n_ctbs);
        p.rs_to_ts = try arena.alloc(u32, n_ctbs);
        p.ts_to_rs = try arena.alloc(u32, n_ctbs);

        // 6.5.1: tile scan visits tiles in raster order, CTBs in raster order inside each
        var ts: u32 = 0;
        for (0..pps.tile_rows.len - 1) |tr| for (0..pps.tile_columns.len - 1) |tc| {
            for (pps.tile_rows[tr]..pps.tile_rows[tr + 1]) |y| for (pps.tile_columns[tc]..pps.tile_columns[tc + 1]) |x| {
                const rs: u32 = @intCast(y * w_ctbs + x);
                p.rs_to_ts[rs] = ts;
                p.ts_to_rs[ts] = rs;
                p.tile_id[rs] = @intCast(tr * (pps.tile_columns.len - 1) + tc);
                ts += 1;
            };
        };
        return p;
    }

    pub fn block(p: *const Picture, x: usize, y: usize) *BlockInfo {
        return &p.blocks[(y >> 2) * p.w4 + (x >> 2)];
    }

    /// Sets `f` on every 4x4 block of a size x size luma area.
    pub fn fillBlocks(p: *Picture, x0: usize, y0: usize, w: usize, h: usize, comptime field: []const u8, value: anytype) void {
        var y = y0;
        while (y < @min(y0 + h, p.height[0])) : (y += 4) {
            var x = x0;
            while (x < @min(x0 + w, p.width[0])) : (x += 4) @field(p.block(x, y), field) = value;
        }
    }

    pub fn ctbAddr(p: *const Picture, x: usize, y: usize) usize {
        const log2 = p.sps.log2_ctb;
        return (y >> log2) * p.sps.widthCtbs() + (x >> log2);
    }

    /// 6.4.1 z-scan availability of luma location (xn, yn) for a block at
    /// (xc, yc): inside the picture, already decoded, same slice and tile.
    pub fn available(p: *const Picture, xc: usize, yc: usize, xn: isize, yn: isize) bool {
        if (xn < 0 or yn < 0 or xn >= p.width[0] or yn >= p.height[0]) return false;
        const nx: usize = @intCast(xn);
        const ny: usize = @intCast(yn);
        const n = p.block(nx, ny);
        if (!n.decoded) return false;
        // same slice: both segments belong to the same independent slice segment
        if (p.sliceStart(n.slice) != p.sliceStart(p.block(xc, yc).slice)) return false;
        return p.tile_id[p.ctbAddr(nx, ny)] == p.tile_id[p.ctbAddr(xc, yc)];
    }

    /// Index of the independent slice segment that slice segment `i` belongs to.
    pub fn sliceStart(p: *const Picture, i: u16) u16 {
        var j = i;
        while (j > 0 and p.slices.items[j].dependent) j -= 1;
        return j;
    }
};
