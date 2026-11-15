//! Multi-scan JPEG decoding: progressive (SOF2) files, and sequential files
//! whose components are split over several scans.
//!
//! The baseline path in jpg.zig turns each block into pixels as soon as it is
//! decoded. Here a scan only adds part of every block (a band of coefficients,
//! or one more bit of precision), so all coefficients are kept until the last
//! scan, then dequantized and inverse-DCT'd into the same planes.
//!
//! Scan types (ITU T.81, annex G):
//!   DC first    ss = 0,  ah = 0   DC difference, shifted left by al
//!   DC refine   ss = 0,  ah > 0   one more DC bit
//!   AC first    ss > 0,  ah = 0   coefficients ss..se, with end-of-band runs
//!   AC refine   ss > 0,  ah > 0   one more bit for nonzero coefficients, plus new ±1s
const std = @import("std");
const Error = @import("../error.zig").Error;
const Header = @import("header.zig");
const BitReader = @import("bitreader.zig");
const Component = @import("component.zig");
const dct = @import("dct.zig");
const jpg = @import("jpg.zig");
const misc = @import("misc.zig");
const ZIGZAG = misc.ZIGZAG;
const ceilDiv = misc.ceilDiv;

/// One block's quantized coefficients, natural (row-major) order.
const Block = [64]i16;

/// Every block of one component, on the padded MCU grid (same size as its plane / 8).
const Grid = struct {
    blocks: []Block,
    /// blocks per row of the padded grid
    stride: usize,
    /// blocks that hold image data (a non-interleaved scan covers only these)
    w: usize,
    h: usize,
};

/// State that lives for one scan.
const Scan = struct {
    br: BitReader,
    pred: [4]i32 = @splat(0),
    /// remaining blocks of the current end-of-band run (AC scans)
    eobrun: u32 = 0,
    blocks_seen: usize = 0,

    fn restartIfNeeded(self: *Scan, interval: u16) !void {
        defer self.blocks_seen += 1;
        if (interval == 0 or self.blocks_seen == 0 or self.blocks_seen % interval != 0) return;
        try self.br.restart();
        self.pred = @splat(0);
        self.eobrun = 0;
    }
};

pub fn decode(scratch: std.mem.Allocator, data: []const u8, first: Header, planes: *const [4]jpg.Plane) !void {
    var hdr = first;
    const mcus_x = ceilDiv(hdr.width, 8 * @as(usize, hdr.h_max));
    const mcus_y = ceilDiv(hdr.height, 8 * @as(usize, hdr.v_max));
    // The grids and planes are sized by the first frame; everything below
    // loops over its component count (a later SOF is rejected by Header).
    const nc = first.n_components;

    var grids: [4]Grid = undefined;
    var n_grids: usize = 0;
    defer for (grids[0..n_grids]) |g| scratch.free(g.blocks);
    for (first.components[0..nc], 0..) |c, i| {
        const stride = mcus_x * c.h;
        grids[i] = .{
            .blocks = try scratch.alloc(Block, stride * mcus_y * c.v),
            .stride = stride,
            .w = ceilDiv(planes[i].w, 8),
            .h = ceilDiv(planes[i].h, 8),
        };
        n_grids += 1;
        @memset(grids[i].blocks, @splat(0));
    }

    while (true) {
        try decodeScan(&hdr, data, &grids, mcus_x, mcus_y);
        if (!try hdr.nextScan(data, Header.entropyEnd(data, hdr.scan_start))) break;
    }
    if (hdr.n_components != nc) return Error.InvalidChunkOrder;

    // Dequantize with the tables in effect at the end, then IDCT into the planes.
    for (first.components[0..nc], 0..) |c, i| {
        const qt = &(hdr.qtables[c.tq] orelse return Error.MissingQuantTable);
        const g = grids[i];
        const p = planes[i];
        for (0..g.blocks.len / g.stride) |by| for (0..g.stride) |bx| {
            const block: @Vector(64, i16) = g.blocks[by * g.stride + bx]; // fixed: one 8x8 block
            const q: @Vector(64, u16) = qt.*;
            const coeffs: [64]f32 = @as(@Vector(64, f32), @floatFromInt(@as(@Vector(64, i32), block) * @as(@Vector(64, i32), q)));
            const dst = p.data[by * 8 * p.stride + bx * 8 ..];
            var ac = block;
            ac[0] = 0;
            if (!@reduce(.Or, ac != @as(@Vector(64, i16), @splat(0)))) { // flat block
                jpg.storeFlat(dct.inverseDc(coeffs[0]), dst, p.stride);
                continue;
            }
            const samples = dct.inverse(&coeffs);
            jpg.storeBlock(&samples, dst, p.stride);
        };
    }
}

fn decodeScan(hdr: *const Header, data: []const u8, grids: *[4]Grid, mcus_x: usize, mcus_y: usize) !void {
    const dc_scan = hdr.ss == 0;
    for (hdr.scan[0..hdr.n_scan]) |ci| {
        const c = hdr.components[ci];
        // DC refinement reads raw bits only; AC scans use only the AC table.
        if (dc_scan and hdr.ah == 0 and hdr.dc_tables[c.td] == null) return Error.MissingHuffmanTable;
        if ((!dc_scan or !hdr.progressive) and hdr.ac_tables[c.ta] == null) return Error.MissingHuffmanTable;
    }

    var scan: Scan = .{ .br = .{ .data = data[hdr.scan_start..] } };
    if (hdr.n_scan == 1) {
        // Non-interleaved: one block per "MCU", covering only the component's real blocks.
        const ci = hdr.scan[0];
        const g = grids[ci];
        for (0..g.h) |by| for (0..g.w) |bx| {
            try scan.restartIfNeeded(hdr.restart_interval);
            try decodeBlock(hdr, hdr.components[ci], &scan, ci, &g.blocks[by * g.stride + bx]);
        };
    } else {
        for (0..mcus_y) |my| for (0..mcus_x) |mx| {
            try scan.restartIfNeeded(hdr.restart_interval);
            for (hdr.scan[0..hdr.n_scan]) |ci| {
                const c = hdr.components[ci];
                const g = grids[ci];
                for (0..c.v) |v| for (0..c.h) |h| {
                    const bx = mx * c.h + h;
                    const by = my * c.v + v;
                    try decodeBlock(hdr, c, &scan, ci, &g.blocks[by * g.stride + bx]);
                };
            }
        };
    }
}

fn decodeBlock(hdr: *const Header, c: Component, scan: *Scan, ci: usize, block: *Block) !void {
    if (!hdr.progressive) return decodeSequential(hdr, c, scan, ci, block);
    if (hdr.ss == 0) {
        if (hdr.ah == 0) return decodeDcFirst(hdr, c, scan, ci, block);
        if (scan.br.readBits(1) != 0) block[0] |= @as(i16, 1) << @intCast(hdr.al);
        return;
    }
    if (hdr.ah == 0) return decodeAcFirst(hdr, c, scan, block);
    return decodeAcRefine(hdr, c, scan, block);
}

/// A complete block from a sequential scan that covers only some components.
fn decodeSequential(hdr: *const Header, c: Component, scan: *Scan, ci: usize, block: *Block) !void {
    try decodeDcFirst(hdr, c, scan, ci, block);
    const ac = &hdr.ac_tables[c.ta].?;
    var k: usize = 1;
    while (k < 64) {
        const sym = try scan.br.decodeAc(ac);
        if (sym.value == 0) {
            if (sym.run != 15) break; // EOB
            k += 16; // ZRL
            continue;
        }
        k += sym.run;
        if (k > 63) return Error.InvalidHuffmanCode;
        block[ZIGZAG[k]] = @truncate(sym.value);
        k += 1;
    }
}

fn decodeDcFirst(hdr: *const Header, c: Component, scan: *Scan, ci: usize, block: *Block) !void {
    const s = try scan.br.decodeSymbol(&hdr.dc_tables[c.td].?);
    if (s > 15) return Error.InvalidHuffmanCode;
    scan.pred[ci] = try jpg.addDc(scan.pred[ci], scan.br.receiveExtend(@intCast(s)));
    // Shift in i64 (pred up to 2^31, al up to 13); the block keeps the low
    // 16 bits, like libjpeg's JCOEF.
    block[0] = @truncate(@as(i64, scan.pred[ci]) << @intCast(hdr.al));
}

fn decodeAcFirst(hdr: *const Header, c: Component, scan: *Scan, block: *Block) !void {
    if (scan.eobrun > 0) {
        scan.eobrun -= 1;
        return;
    }
    const ac = &hdr.ac_tables[c.ta].?;
    var k: usize = hdr.ss;
    while (k <= hdr.se) {
        const sym = try scan.br.decodeAc(ac);
        if (sym.value == 0) {
            if (sym.run < 15) {
                // EOBn: this block and the next 2^run - 1 + extra blocks end here
                scan.eobrun = (@as(u32, 1) << sym.run) - 1 + scan.br.readBits(sym.run);
                return;
            }
            k += 16; // ZRL
            continue;
        }
        k += sym.run;
        if (k > hdr.se) return Error.InvalidHuffmanCode;
        block[ZIGZAG[k]] = @truncate(sym.value << @intCast(hdr.al));
        k += 1;
    }
}

/// G.1.2.3: coefficients that are already nonzero get one correction bit each;
/// a zero coefficient can become ±(1 << al). Runs count only zero coefficients.
fn decodeAcRefine(hdr: *const Header, c: Component, scan: *Scan, block: *Block) !void {
    const bit: i16 = @as(i16, 1) << @intCast(hdr.al);
    var k: usize = hdr.ss;

    if (scan.eobrun == 0) {
        const ac = &hdr.ac_tables[c.ta].?;
        while (k <= hdr.se) {
            const rs = try scan.br.decodeSymbol(ac);
            var run: u32 = rs >> 4;
            const size = rs & 0xF;
            var value: i16 = 0;
            if (size == 0) {
                if (run < 15) {
                    // EOBn: the rest of this block (and the next eobrun blocks)
                    // only refine existing coefficients.
                    scan.eobrun = (@as(u32, 1) << @intCast(run)) + scan.br.readBits(@intCast(run));
                    break;
                }
                // ZRL: skip 16 zero coefficients (refining nonzero ones on the way)
            } else {
                if (size != 1) return Error.InvalidHuffmanCode;
                value = if (scan.br.readBits(1) != 0) bit else -bit;
            }
            while (k <= hdr.se) {
                const coef = &block[ZIGZAG[k]];
                k += 1;
                if (coef.* != 0) {
                    refine(scan, coef, bit);
                } else {
                    if (run == 0) {
                        coef.* = value;
                        break;
                    }
                    run -= 1;
                }
            }
        }
    }
    if (scan.eobrun > 0) {
        // Inside an end-of-band run: refine the remaining nonzero coefficients.
        while (k <= hdr.se) : (k += 1) {
            const coef = &block[ZIGZAG[k]];
            if (coef.* != 0) refine(scan, coef, bit);
        }
        scan.eobrun -= 1;
    }
}

test "progressive DC first: large predictor shifted by al, predictor overflow" {
    const huffman = @import("huffman.zig");
    var hdr: Header = .{};
    hdr.progressive = true;
    hdr.al = 13;
    var bits: [16]u8 = @splat(0);
    bits[0] = 1; // one 1-bit code "0": size category 15
    hdr.dc_tables[0] = try huffman.DecTable.init(.{ .bits = bits, .values = &.{15} });
    const c: Component = .{ .id = 1, .h = 1, .v = 1, .tq = 0 };
    const stream = [_]u8{ 0x7F, 0xFF, 0x00, 0x00 }; // "0" + 15 one bits: +32767
    var block: Block = @splat(0);

    var scan: Scan = .{ .br = .{ .data = &stream } };
    scan.pred[0] = 1 << 20; // (2^20 + 32767) << 13 does not fit i32
    try decodeDcFirst(&hdr, c, &scan, 0, &block);
    try std.testing.expectEqual(@as(i16, @truncate(@as(i64, (1 << 20) + 32767) << 13)), block[0]);

    scan = .{ .br = .{ .data = &stream } };
    scan.pred[0] = std.math.maxInt(i32);
    try std.testing.expectError(Error.Overflow, decodeDcFirst(&hdr, c, &scan, 0, &block));
}

/// Adds the next lower bit to a nonzero coefficient, moving it away from zero.
fn refine(scan: *Scan, coef: *i16, bit: i16) void {
    if (scan.br.readBits(1) == 0 or coef.* & bit != 0) return;
    coef.* += if (coef.* > 0) bit else -bit;
}
