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
/// indices into `components`, in scan order
scan: [4]u8 = undefined,
n_scan: u8 = 0,
/// offset of the first entropy-coded byte
scan_start: usize = 0,

pub const ParseUntil = enum { frame, scan };

/// `.frame` stops after SOF (cheap, for `info`), `.scan` parses through SOS.
pub fn decode(data: []const u8, until: ParseUntil) Error!@This() {
    if (data.len < 4 or data[0] != 0xFF or data[1] != @intFromEnum(Marker.SOI))
        return Error.UnexpectedSignature;
    var hdr: @This() = .{};
    var found_frame = false;
    var pos: usize = 2;
    while (true) {
        // markers may be preceded by any number of 0xFF fill bytes
        if (pos >= data.len or data[pos] != 0xFF) return Error.InvalidMarker;
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) return Error.UnexpectedEndOfData;
        const marker: Marker = @enumFromInt(data[pos]);
        pos += 1;
        switch (marker) {
            .SOI, .RST0, .RST1, .RST2, .RST3, .RST4, .RST5, .RST6, .RST7 => continue,
            .EOI => return Error.MissingScan,
            else => {},
        }
        if (pos + 2 > data.len) return Error.UnexpectedEndOfData;
        const seg_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        if (seg_len < 2 or pos + seg_len > data.len) return Error.UnexpectedEndOfData;
        const seg = data[pos + 2 .. pos + seg_len];
        pos += seg_len;

        switch (marker) {
            .SOF0, .SOF1 => {
                try hdr.decodeFrame(seg);
                found_frame = true;
                if (until == .frame) return hdr;
            },
            .SOF2, .SOF6, .SOF10, .SOF14 => return Error.UnsupportedProgressive,
            .SOF3, .SOF5, .SOF7, .SOF9, .SOF11, .SOF13, .SOF15 => return Error.UnsupportedFeature,
            .DQT => try hdr.decodeQuant(seg),
            .DHT => try hdr.decodeHuffman(seg),
            .DRI => {
                if (seg.len < 2) return Error.InvalidChunkLen;
                hdr.restart_interval = std.mem.readInt(u16, seg[0..2], .big);
            },
            .SOS => {
                if (!found_frame) return Error.MissingFrame;
                try hdr.decodeScan(seg);
                hdr.scan_start = pos;
                return hdr;
            },
            else => {}, // APPn, COM, ... skipped
        }
    }
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

fn decodeHuffman(self: *@This(), seg: []const u8) Error!void {
    var sp: usize = 0;
    while (sp < seg.len) {
        const class = seg[sp] >> 4;
        const id = seg[sp] & 0xF;
        sp += 1;
        if (class > 1 or id > 3 or sp + 16 > seg.len) return Error.InvalidHeader;
        const bits = seg[sp..][0..16].*;
        sp += 16;
        var total: usize = 0;
        for (bits) |b| total += b;
        if (sp + total > seg.len) return Error.InvalidChunkLen;
        const table = try huffman.DecTable.init(.{ .bits = bits, .values = seg[sp..][0..total] });
        sp += total;
        if (class == 0) self.dc_tables[id] = table else self.ac_tables[id] = table;
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
    // baseline: all components must be in this single scan
    if (ns != self.n_components) return Error.UnsupportedFeature;
}
