//! In-loop filters (H.265 8.7): deblocking, then sample adaptive offset.
//! Pictures are intra-only, so every transform / prediction edge has bS = 2.
const std = @import("std");
const Allocator = std.mem.Allocator;
const picture = @import("picture.zig");
const Picture = picture.Picture;
const BlockInfo = picture.BlockInfo;
const tables = @import("tables.zig");

pub fn apply(arena: Allocator, pic: *Picture) !void {
    // all vertical edges of the picture, then all horizontal ones (8.7.2)
    deblock(pic, .vertical);
    deblock(pic, .horizontal);
    if (pic.sps.sao_enabled) try sao(arena, pic);
}

const Dir = enum { vertical, horizontal };

/// One edge segment: the line through q0 runs `across` the edge, lines follow `along` it.
const Edge = struct {
    plane: []u16,
    q0: usize, // index of q0 on line 0
    across: usize,
    along: usize,

    fn get(e: Edge, line: usize, i: isize) i32 {
        const idx: isize = @as(isize, @intCast(e.q0 + line * e.along)) + i * @as(isize, @intCast(e.across));
        return e.plane[@intCast(idx)];
    }
    fn set(e: Edge, line: usize, i: isize, v: i32) void {
        const idx: isize = @as(isize, @intCast(e.q0 + line * e.along)) + i * @as(isize, @intCast(e.across));
        e.plane[@intCast(idx)] = @intCast(v);
    }
};

/// 8.7.2: edges on the 8x8 luma grid, processed in 4-sample segments.
fn deblock(pic: *Picture, dir: Dir) void {
    const w = pic.width[0];
    const h = pic.height[0];
    var y: usize = 0;
    while (y < h) : (y += 4) {
        var x: usize = 0;
        while (x < w) : (x += 4) {
            const pos = if (dir == .vertical) x else y;
            if (pos == 0 or pos % 8 != 0) continue;
            const q = pic.block(x, y);
            if (!(if (dir == .vertical) q.edge_left else q.edge_top)) continue;
            const px = if (dir == .vertical) x - 1 else x;
            const py = if (dir == .vertical) y else y - 1;
            const p = pic.block(px, py);
            const hdr = &pic.slices.items[q.slice];
            if (hdr.deblocking_disabled) continue;
            if (pic.tile_id[pic.ctbAddr(x, y)] != pic.tile_id[pic.ctbAddr(px, py)] and !pic.pps.loop_filter_across_tiles) continue;
            if (pic.sliceStart(p.slice) != pic.sliceStart(q.slice) and !hdr.loop_filter_across_slices) continue;

            const stride = pic.width[0];
            lumaEdge(pic, .{
                .plane = pic.planes[0],
                .q0 = y * stride + x,
                .across = if (dir == .vertical) 1 else stride,
                .along = if (dir == .vertical) stride else 1,
            }, p, q, hdr.beta_offset_div2, hdr.tc_offset_div2);

            // 4:2:0 chroma: edges on the 8x8 chroma grid (16 luma samples)
            if (pic.sps.chroma_format_idc == 1 and pos % 16 == 0) {
                const cs = pic.width[1];
                for ([_]usize{ 1, 2 }) |c| {
                    const offset = if (c == 1) pic.pps.cb_qp_offset else pic.pps.cr_qp_offset;
                    chromaEdge(pic, .{
                        .plane = pic.planes[c],
                        .q0 = (y >> 1) * cs + (x >> 1),
                        .across = if (dir == .vertical) 1 else cs,
                        .along = if (dir == .vertical) cs else 1,
                    }, p, q, offset, hdr.tc_offset_div2);
                }
            }
        }
    }
}

fn lumaEdge(pic: *const Picture, e: Edge, p: *const BlockInfo, q: *const BlockInfo, beta_offset_div2: i32, tc_offset_div2: i32) void {
    const bd = pic.sps.bit_depth_luma;
    const qp = (@as(i32, p.qp_y) + q.qp_y + 1) >> 1;
    const beta = @as(i32, tables.beta_table[@intCast(std.math.clamp(qp + beta_offset_div2 * 2, 0, 51))]) << @intCast(bd - 8);
    const tc = @as(i32, tables.tc_table[@intCast(std.math.clamp(qp + 2 + tc_offset_div2 * 2, 0, 53))]) << @intCast(bd - 8);
    if (tc == 0 and beta == 0) return;

    const dp0 = @abs(e.get(0, -3) - 2 * e.get(0, -2) + e.get(0, -1));
    const dp3 = @abs(e.get(3, -3) - 2 * e.get(3, -2) + e.get(3, -1));
    const dq0 = @abs(e.get(0, 2) - 2 * e.get(0, 1) + e.get(0, 0));
    const dq3 = @abs(e.get(3, 2) - 2 * e.get(3, 1) + e.get(3, 0));
    const d = dp0 + dq0 + dp3 + dq3;
    if (d >= beta) return;

    const strong = strongLine(e, 0, 2 * (dp0 + dq0), beta, tc) and strongLine(e, 3, 2 * (dp3 + dq3), beta, tc);
    const side = (beta + (beta >> 1)) >> 3;
    const filter_p = !p.no_filter;
    const filter_q = !q.no_filter;
    const max: i32 = (@as(i32, 1) << @intCast(bd)) - 1;

    for (0..4) |k| {
        const p0 = e.get(k, -1);
        const p1 = e.get(k, -2);
        const p2 = e.get(k, -3);
        const q0 = e.get(k, 0);
        const q1 = e.get(k, 1);
        const q2 = e.get(k, 2);
        if (strong) {
            const p3 = e.get(k, -4);
            const q3 = e.get(k, 3);
            const t2 = 2 * tc;
            if (filter_p) {
                e.set(k, -1, std.math.clamp((p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4) >> 3, p0 - t2, p0 + t2));
                e.set(k, -2, std.math.clamp((p2 + p1 + p0 + q0 + 2) >> 2, p1 - t2, p1 + t2));
                e.set(k, -3, std.math.clamp((2 * p3 + 3 * p2 + p1 + p0 + q0 + 4) >> 3, p2 - t2, p2 + t2));
            }
            if (filter_q) {
                e.set(k, 0, std.math.clamp((p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4) >> 3, q0 - t2, q0 + t2));
                e.set(k, 1, std.math.clamp((p0 + q0 + q1 + q2 + 2) >> 2, q1 - t2, q1 + t2));
                e.set(k, 2, std.math.clamp((p0 + q0 + q1 + 3 * q2 + 2 * q3 + 4) >> 3, q2 - t2, q2 + t2));
            }
        } else {
            var delta = (9 * (q0 - p0) - 3 * (q1 - p1) + 8) >> 4;
            if (@abs(delta) >= tc * 10) continue;
            delta = std.math.clamp(delta, -tc, tc);
            if (filter_p) {
                e.set(k, -1, std.math.clamp(p0 + delta, 0, max));
                if (dp0 + dp3 < side) {
                    const dp = std.math.clamp((((p2 + p0 + 1) >> 1) - p1 + delta) >> 1, -(tc >> 1), tc >> 1);
                    e.set(k, -2, std.math.clamp(p1 + dp, 0, max));
                }
            }
            if (filter_q) {
                e.set(k, 0, std.math.clamp(q0 - delta, 0, max));
                if (dq0 + dq3 < side) {
                    const dq = std.math.clamp((((q2 + q0 + 1) >> 1) - q1 - delta) >> 1, -(tc >> 1), tc >> 1);
                    e.set(k, 1, std.math.clamp(q1 + dq, 0, max));
                }
            }
        }
    }
}

fn strongLine(e: Edge, k: usize, dpq: u32, beta: i32, tc: i32) bool {
    const p0 = e.get(k, -1);
    const q0 = e.get(k, 0);
    return dpq < (beta >> 2) and
        @abs(e.get(k, -4) - p0) + @abs(q0 - e.get(k, 3)) < (beta >> 3) and
        @abs(p0 - q0) < ((5 * tc + 1) >> 1);
}

/// Two chroma lines of a 4-luma-sample segment.
fn chromaEdge(pic: *const Picture, e: Edge, p: *const BlockInfo, q: *const BlockInfo, qp_offset: i32, tc_offset_div2: i32) void {
    const bd = pic.sps.bit_depth_chroma;
    const qpc = tables.chromaQp(((@as(i32, p.qp_y) + q.qp_y + 1) >> 1) + qp_offset);
    const tc = @as(i32, tables.tc_table[@intCast(std.math.clamp(qpc + 2 + tc_offset_div2 * 2, 0, 53))]) << @intCast(bd - 8);
    if (tc == 0) return;
    const max: i32 = (@as(i32, 1) << @intCast(bd)) - 1;
    for (0..2) |k| {
        const p0 = e.get(k, -1);
        const q0 = e.get(k, 0);
        const delta = std.math.clamp((((q0 - p0) << 2) + e.get(k, -2) - e.get(k, 1) + 4) >> 3, -tc, tc);
        if (!p.no_filter) e.set(k, -1, std.math.clamp(p0 + delta, 0, max));
        if (!q.no_filter) e.set(k, 0, std.math.clamp(q0 - delta, 0, max));
    }
}

/// 8.7.3: sample adaptive offset, reading the deblocked picture from a copy.
fn sao(arena: Allocator, pic: *Picture) !void {
    const sps = pic.sps;
    const w_ctbs = sps.widthCtbs();
    const n_comp: usize = if (sps.chroma_format_idc == 0) 1 else 3;
    var src: [3][]const u16 = undefined;
    for (0..n_comp) |c| src[c] = try arena.dupe(u16, pic.planes[c]);

    for (0..sps.heightCtbs()) |ry| for (0..w_ctbs) |rx| {
        const params = pic.sao[ry * w_ctbs + rx];
        for (0..n_comp) |c| {
            if (params.type[c] == 0) continue;
            const shift: u6 = if (c == 0) 0 else pic.chroma_shift;
            const size = sps.ctbSize() >> @intCast(shift);
            const x0 = rx * size;
            const y0 = ry * size;
            const x1 = @min(x0 + size, pic.width[c]);
            const y1 = @min(y0 + size, pic.height[c]);
            const bd = if (c == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
            const max: i32 = (@as(i32, 1) << @intCast(bd)) - 1;
            const offsets: [5]i32 = .{ 0, params.offset[c][0], params.offset[c][1], params.offset[c][2], params.offset[c][3] };
            if (params.type[c] == 1) {
                var band: [32]u8 = @splat(0);
                for (0..4) |k| band[(k + params.band_position[c]) & 31] = @intCast(k + 1);
                const band_shift: u5 = @intCast(bd - 5);
                for (y0..y1) |y| for (x0..x1) |x| {
                    if (pic.block(x << shift, y << shift).no_filter) continue;
                    const i = y * pic.width[c] + x;
                    const v: i32 = src[c][i];
                    pic.planes[c][i] = @intCast(std.math.clamp(v + offsets[band[@intCast(v >> band_shift)]], 0, max));
                };
            } else {
                const dirs = [4][2][2]i8{
                    .{ .{ -1, 0 }, .{ 1, 0 } },
                    .{ .{ 0, -1 }, .{ 0, 1 } },
                    .{ .{ -1, -1 }, .{ 1, 1 } },
                    .{ .{ 1, -1 }, .{ -1, 1 } },
                };
                const dir = dirs[params.eo_class[c]];
                for (y0..y1) |y| for (x0..x1) |x| {
                    const cur = pic.block(x << shift, y << shift);
                    if (cur.no_filter) continue;
                    const i = y * pic.width[c] + x;
                    const v: i32 = src[c][i];
                    var edge: i32 = 2;
                    var ok = true;
                    for (dir) |o| {
                        const nx = @as(isize, @intCast(x)) + o[0];
                        const ny = @as(isize, @intCast(y)) + o[1];
                        if (nx < 0 or ny < 0 or nx >= pic.width[c] or ny >= pic.height[c]) {
                            ok = false;
                            break;
                        }
                        const ux: usize = @intCast(nx);
                        const uy: usize = @intCast(ny);
                        if (!saoNeighbourUsable(pic, cur, ux << shift, uy << shift, x << shift, y << shift)) {
                            ok = false;
                            break;
                        }
                        edge += std.math.sign(v - @as(i32, src[c][uy * pic.width[c] + ux]));
                    }
                    if (!ok) continue;
                    const idx: usize = switch (edge) {
                        0 => 1,
                        1 => 2,
                        2 => 0,
                        else => @intCast(edge),
                    };
                    pic.planes[c][i] = @intCast(std.math.clamp(v + offsets[idx], 0, max));
                };
            }
        }
    };
}

/// 8.7.3.2: neighbours across slice / tile boundaries may be excluded.
fn saoNeighbourUsable(pic: *const Picture, cur: *const BlockInfo, nx: usize, ny: usize, x: usize, y: usize) bool {
    const n = pic.block(nx, ny);
    if (n.slice != cur.slice and pic.sliceStart(n.slice) != pic.sliceStart(cur.slice)) {
        // the later slice (in decoding order) decides
        const later = if (n.slice > cur.slice) n.slice else cur.slice;
        if (!pic.slices.items[later].loop_filter_across_slices) return false;
    }
    if (!pic.pps.loop_filter_across_tiles and pic.tile_id[pic.ctbAddr(nx, ny)] != pic.tile_id[pic.ctbAddr(x, y)]) return false;
    return true;
}
