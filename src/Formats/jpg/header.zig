//! Everything before the entropy-coded data: frame, tables, scan.
const std = @import("std");
const Error = @import("../error.zig").Error;
const misc = @import("misc.zig");
const huffman = @import("huffman.zig");
const Component = @import("component.zig");
const Marker = misc.Marker;

width: u32 = 0,
height: u32 = 0,
components: [4]Component = undefined,
n_components: u8 = 0,
h_max: u8 = 1,
v_max: u8 = 1,
/// natural order
qtables: [4]?[64]u16 = @splat(null),
dc_tables: [4]?huffman.DecTable = @splat(null),
ac_tables: [4]?huffman.DecTable = @splat(null),
restart_interval: u16 = 0,
/// SOF2: coefficients arrive over several scans (see progressive.zig)
progressive: bool = false,
/// SOF3: a lossless frame; parsing stopped at its marker (lossless.zig reads it)
lossless: bool = false,
/// indices into `components`, in scan order
scan: [4]u8 = undefined,
n_scan: u8 = 0,
/// Current scan's spectral selection (zigzag indices `ss..se`) and successive
/// approximation bit positions. Sequential scans always cover 0..63, ah = al = 0.
ss: u8 = 0,
se: u8 = 63,
ah: u8 = 0,
al: u8 = 0,
/// offset of the first entropy-coded byte
scan_start: usize = 0,

pub const ParseUntil = enum { frame, scan };

/// `.frame` stops after SOF (cheap, for `info`), `.scan` parses through the first SOS.
pub fn decode(data: []const u8, until: ParseUntil) Error!@This() {
    if (data.len < 4 or data[0] != 0xFF or data[1] != @backingInt(Marker.SOI))
        return Error.UnexpectedSignature;
    var hdr: @This() = .{};
    if (!try hdr.parse(data, 2, until)) return Error.MissingScan;
    return hdr;
}

/// Continues after a scan's entropy-coded data (`pos` = offset of the next
/// marker), applying any tables defined in between. Returns false at EOI.
pub fn nextScan(self: *@This(), data: []const u8, pos: usize) Error!bool {
    if (pos >= data.len) return false; // truncated after a complete scan: keep what we have
    return self.parse(data, pos, .scan);
}

pub const entropyEnd = misc.entropyEnd;

/// Parses segments from the marker at `start` until a frame (`.frame`) or a
/// scan (`.scan`) is found (true), or EOI (false). A lossless (SOF3) frame stops
/// the parse at once with `lossless` set: lossless.zig reads those streams.
fn parse(self: *@This(), data: []const u8, start: usize, until: ParseUntil) Error!bool {
    var it: misc.Segments = .{ .data = data, .pos = start };
    while (try it.next()) |s| {
        const seg = s.body;
        switch (s.marker) {
            .SOI, .TEM, .RST0, .RST1, .RST2, .RST3, .RST4, .RST5, .RST6, .RST7 => {},
            .EOI => return false,
            .SOF0, .SOF1, .SOF2 => {
                try self.decodeFrame(seg);
                self.progressive = s.marker == .SOF2;
                if (until == .frame) return true;
            },
            .SOF3 => {
                self.lossless = true;
                return true;
            },
            // differential and arithmetic-coded frames
            .SOF5, .SOF6, .SOF7, .SOF9, .SOF10, .SOF11, .SOF13, .SOF14, .SOF15 => return Error.UnsupportedFeature,
            .DQT => try self.decodeQuant(seg),
            .DHT => try huffman.parseDht(seg, &self.dc_tables, &self.ac_tables),
            .DRI => {
                if (seg.len < 2) return Error.InvalidChunkLen;
                self.restart_interval = std.mem.readInt(u16, seg[0..2], .big);
            },
            .SOS => {
                if (self.n_components == 0) return Error.MissingFrame;
                try self.decodeScan(seg);
                self.scan_start = it.pos;
                return true;
            },
            else => {}, // APPn, COM, ... skipped
        }
    }
    return Error.InvalidMarker; // ran out of data before a frame / scan / EOI
}

fn decodeFrame(self: *@This(), seg: []const u8) Error!void {
    if (seg.len < 6) return Error.InvalidChunkLen;
    if (seg[0] != 8) return Error.UnsupportedDepth;
    self.height = std.mem.readInt(u16, seg[1..3], .big);
    self.width = std.mem.readInt(u16, seg[3..5], .big);
    if (self.width == 0 or self.height == 0) return Error.InvalidDimensions; // DNL unsupported
    const nc = seg[5];
    if (nc != 1 and nc != 3) return Error.InvalidComponentCount; // CMYK unsupported
    if (seg.len < 6 + @as(usize, nc) * 3) return Error.InvalidChunkLen;
    self.n_components = nc;
    self.h_max = 1;
    self.v_max = 1;
    for (0..nc) |i| {
        const c = seg[6 + i * 3 ..][0..3];
        const h = c[1] >> 4;
        const v = c[1] & 0xF;
        if (h == 0 or h > 4 or v == 0 or v > 4 or c[2] > 3) return Error.InvalidHeader;
        self.components[i] = .{ .id = c[0], .h = h, .v = v, .tq = c[2] };
        self.h_max = @max(self.h_max, h);
        self.v_max = @max(self.v_max, v);
    }
}

fn decodeQuant(self: *@This(), seg: []const u8) Error!void {
    var sp: usize = 0;
    while (sp < seg.len) {
        const pq = seg[sp] >> 4;
        const tq = seg[sp] & 0xF;
        sp += 1;
        if (tq > 3) return Error.InvalidHeader;
        var table: [64]u16 = undefined;
        if (pq == 0) {
            if (sp + 64 > seg.len) return Error.InvalidChunkLen;
            for (0..64) |k| table[misc.ZIGZAG[k]] = seg[sp + k];
            sp += 64;
        } else {
            if (sp + 128 > seg.len) return Error.InvalidChunkLen;
            for (0..64) |k| table[misc.ZIGZAG[k]] = std.mem.readInt(u16, seg[sp + 2 * k ..][0..2], .big);
            sp += 128;
        }
        self.qtables[tq] = table;
    }
}

fn decodeScan(self: *@This(), seg: []const u8) Error!void {
    if (seg.len < 1) return Error.InvalidChunkLen;
    const ns = seg[0];
    if (ns == 0 or ns > self.n_components or seg.len < 1 + @as(usize, ns) * 2 + 3)
        return Error.InvalidComponentCount;
    for (0..ns) |i| {
        const cs = seg[1 + i * 2];
        const t = seg[2 + i * 2];
        const ci = for (self.components[0..self.n_components], 0..) |c, j| {
            if (c.id == cs) break j;
        } else return Error.InvalidHeader;
        self.components[ci].td = t >> 4;
        self.components[ci].ta = t & 0xF;
        if (self.components[ci].td > 3 or self.components[ci].ta > 3) return Error.InvalidHeader;
        self.scan[i] = @intCast(ci);
    }
    self.n_scan = ns;
    const tail = seg[1 + @as(usize, ns) * 2 ..][0..3];
    if (self.progressive) {
        self.ss = tail[0];
        self.se = tail[1];
        self.ah = tail[2] >> 4;
        self.al = tail[2] & 0xF;
        // G.1.1.1.1: a DC scan has ss = se = 0; AC scans hold one component
        const valid = self.ss <= self.se and self.se <= 63 and
            (self.ss != 0 or self.se == 0) and (self.ss == 0 or ns == 1) and
            self.ah <= 13 and self.al <= 13;
        if (!valid) return Error.InvalidHeader;
    } else {
        // sequential: every scan carries complete blocks
        self.ss = 0;
        self.se = 63;
        self.ah = 0;
        self.al = 0;
    }
}
