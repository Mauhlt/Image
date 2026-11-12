//! Canonical Huffman tables (JPEG Annex C / F.2.2.3) + the Annex K standard tables.
const std = @import("std");
const Error = @import("../error.zig").Error;

/// `bits[i]` = number of codes of length i + 1, `values` = symbols in code order.
pub const Spec = struct {
    bits: [16]u8,
    values: []const u8,
};

pub const STD_DC_LUMA: Spec = .{
    .bits = .{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
    .values = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
};

pub const STD_DC_CHROMA: Spec = .{
    .bits = .{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 },
    .values = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
};

pub const STD_AC_LUMA: Spec = .{
    .bits = .{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d },
    .values = &.{
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    },
};

pub const STD_AC_CHROMA: Spec = .{
    .bits = .{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 },
    .values = &.{
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa,
    },
};

pub const LOOKAHEAD = 9;

/// Decoding table: codes of length <= LOOKAHEAD resolve with one table lookup,
/// longer codes use the per-length max-code walk (F.2.2.3).
pub const DecTable = struct {
    /// (len << 8) | symbol, len == 0 -> code longer than LOOKAHEAD
    lookup: [1 << LOOKAHEAD]u16 = @splat(0),
    /// largest code of each length (index 1..16), -1 = none
    maxcode: [17]i32 = @splat(-1),
    /// symbol index = code + delta[len]
    delta: [17]i32 = @splat(0),
    values: [256]u8 = @splat(0),
    /// AC symbol and its value bits in one lookup, when both fit in LOOKAHEAD bits:
    /// (value << 8) | (run << 4) | total_len. 0 -> not covered (incl. EOB/ZRL),
    /// so a nonzero entry always has a nonzero value.
    fast_ac: [1 << LOOKAHEAD]i16 = @splat(0),

    pub fn init(spec: Spec) Error!DecTable {
        var t: DecTable = .{};
        var total: usize = 0;
        for (spec.bits) |b| total += b;
        if (total > 256 or total > spec.values.len) return Error.InvalidHuffmanCode;
        @memcpy(t.values[0..total], spec.values[0..total]);

        var code: u32 = 0;
        var k: usize = 0;
        for (1..17) |len| {
            const count = spec.bits[len - 1];
            if (count > 0) {
                t.delta[len] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
                for (0..count) |_| {
                    if (len <= LOOKAHEAD) {
                        const shift: u4 = @intCast(LOOKAHEAD - len);
                        const first = code << shift;
                        const entry: u16 = (@as(u16, @intCast(len)) << 8) | t.values[k];
                        for (first..first + (@as(u32, 1) << shift)) |i| t.lookup[i] = entry;
                    }
                    code += 1;
                    k += 1;
                }
                t.maxcode[len] = @as(i32, @intCast(code)) - 1;
            }
            if (code > (@as(u32, 1) << @intCast(len))) return Error.InvalidHuffmanCode;
            code <<= 1;
        }

        for (&t.fast_ac, t.lookup, 0..) |*fast, entry, i| {
            const len = entry >> 8;
            const run = (entry >> 4) & 0xF;
            const size = entry & 0xF;
            // size <= 7 keeps |value| <= 127, so it fits the top byte
            if (len == 0 or size == 0 or size > 7 or len + size > LOOKAHEAD) continue;
            const bits: i16 = @intCast((i >> @intCast(LOOKAHEAD - len - size)) & ((@as(usize, 1) << @intCast(size)) - 1));
            const value = if (bits < @as(i16, 1) << @intCast(size - 1)) bits - (@as(i16, 1) << @intCast(size)) + 1 else bits;
            fast.* = value * 256 + @as(i16, @intCast((run << 4) | (len + size)));
        }
        return t;
    }
};

/// Builds the tables of one DHT segment body into `dc` (class 0) / `ac` (class 1).
pub fn parseDht(seg: []const u8, dc: *[4]?DecTable, ac: *[4]?DecTable) Error!void {
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
        const table = try DecTable.init(.{ .bits = bits, .values = seg[sp..][0..total] });
        sp += total;
        if (class == 0) dc[id] = table else ac[id] = table;
    }
}

pub const EncEntry = struct { code: u16 = 0, len: u8 = 0 };

/// Encoding table indexed by symbol.
pub fn encTable(spec: Spec) [256]EncEntry {
    var t: [256]EncEntry = @splat(.{});
    var code: u16 = 0;
    var k: usize = 0;
    for (1..17) |len| {
        for (0..spec.bits[len - 1]) |_| {
            t[spec.values[k]] = .{ .code = code, .len = @intCast(len) };
            code += 1;
            k += 1;
        }
        code <<= 1;
    }
    return t;
}

test "huffman tables agree" {
    for ([_]Spec{ STD_DC_LUMA, STD_DC_CHROMA, STD_AC_LUMA, STD_AC_CHROMA }) |spec| {
        const dec = try DecTable.init(spec);
        const enc = encTable(spec);
        for (spec.values) |sym| {
            const e = enc[sym];
            try std.testing.expect(e.len > 0);
            if (e.len <= LOOKAHEAD) {
                const idx = @as(u32, e.code) << @intCast(LOOKAHEAD - e.len);
                try std.testing.expectEqual(@as(u16, e.len) << 8 | sym, dec.lookup[idx]);
            } else {
                try std.testing.expect(@as(i32, e.code) <= dec.maxcode[e.len]);
                try std.testing.expectEqual(sym, dec.values[@intCast(@as(i32, e.code) + dec.delta[e.len])]);
            }
        }
    }
}
