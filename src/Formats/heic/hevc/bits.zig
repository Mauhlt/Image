//! HEVC NAL units (ITU-T H.265 7.3.1): emulation prevention removal and an
//! MSB-first bit reader with the Exp-Golomb codes used by parameter sets and
//! slice headers.
const std = @import("std");
const Error = @import("../../error.zig").Error;

pub const NalType = enum(u6) {
    idr_w_radl = 19,
    idr_n_lp = 20,
    cra = 21,
    vps = 32,
    sps = 33,
    pps = 34,
    _,

    /// Coded slice segment of a picture (VCL NAL unit).
    pub fn isSlice(t: NalType) bool {
        return @intFromEnum(t) < 32;
    }
};

pub const Nal = struct {
    type: NalType,
    /// payload after the 2-byte header, emulation prevention bytes removed
    rbsp: []const u8,
    /// positions (in the escaped payload) of removed 0x03 bytes, ascending,
    /// to translate entry point offsets (which count them) into rbsp offsets
    removed: []const usize,

    /// Maps an offset in the escaped payload to the rbsp.
    pub fn rbspOffset(nal: Nal, escaped: usize) usize {
        var n: usize = 0;
        for (nal.removed) |p| {
            if (p >= escaped) break;
            n += 1;
        }
        return escaped - n;
    }
};

/// Parses one NAL unit (without length prefix / start code).
pub fn parseNal(arena: std.mem.Allocator, data: []const u8) !Nal {
    if (data.len < 2) return Error.UnexpectedEndOfData;
    const t: NalType = @enumFromInt(@as(u6, @truncate(data[0] >> 1)));
    const payload = data[2..];
    var out: std.ArrayList(u8) = try .initCapacity(arena, payload.len);
    var removed: std.ArrayList(usize) = .empty;
    var zeros: usize = 0;
    for (payload, 0..) |b, i| {
        // 0x000003 -> 0x0000: the 03 only stops the payload looking like a start code
        if (zeros >= 2 and b == 0x03) {
            zeros = 0;
            try removed.append(arena, i);
            continue;
        }
        zeros = if (b == 0) zeros + 1 else 0;
        out.appendAssumeCapacity(b);
    }
    return .{ .type = t, .rbsp = out.items, .removed = removed.items };
}

pub const BitReader = struct {
    data: []const u8,
    /// position in bits
    pos: usize = 0,

    pub fn bit(r: *BitReader) Error!u1 {
        if (r.pos >= r.data.len * 8) return Error.UnexpectedEndOfData;
        defer r.pos += 1;
        return @truncate(r.data[r.pos >> 3] >> @intCast(7 - (r.pos & 7)));
    }

    pub fn flag(r: *BitReader) Error!bool {
        return try r.bit() == 1;
    }

    pub fn bits(r: *BitReader, n: u6) Error!u32 {
        std.debug.assert(n <= 32);
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | try r.bit();
        return v;
    }

    pub fn skip(r: *BitReader, n: usize) Error!void {
        if (r.pos + n > r.data.len * 8) return Error.UnexpectedEndOfData;
        r.pos += n;
    }

    /// ue(v): unsigned Exp-Golomb.
    pub fn ue(r: *BitReader) Error!u32 {
        var zeros: u6 = 0;
        while (try r.bit() == 0) {
            zeros += 1;
            if (zeros > 31) return Error.InvalidHeader;
        }
        if (zeros == 0) return 0;
        return @intCast((@as(u64, 1) << zeros) - 1 + try r.bits(zeros));
    }

    /// se(v): signed Exp-Golomb (1 -> 1, 2 -> -1, 3 -> 2, ...).
    pub fn se(r: *BitReader) Error!i32 {
        const k = try r.ue();
        const m: i32 = @intCast((k + 1) / 2);
        return if (k & 1 == 1) m else -m;
    }

    /// ue(v) that must be <= max.
    pub fn ueMax(r: *BitReader, max: u32) Error!u32 {
        const v = try r.ue();
        return if (v > max) Error.InvalidHeader else v;
    }

    pub fn byteAligned(r: *const BitReader) bool {
        return r.pos & 7 == 0;
    }

    pub fn alignToByte(r: *BitReader) void {
        r.pos = (r.pos + 7) & ~@as(usize, 7);
    }
};

test "exp-golomb" {
    // 1 | 010 | 011 | 00100 | 00101 -> ue 0,1,2,3,4 ; then se of 010 (k=1) = 1, 011 (k=2) = -1
    var r: BitReader = .{ .data = &.{ 0b1010_0110, 0b0100_0010, 0b1010_0110 } };
    try std.testing.expectEqual(@as(u32, 0), try r.ue());
    try std.testing.expectEqual(@as(u32, 1), try r.ue());
    try std.testing.expectEqual(@as(u32, 2), try r.ue());
    try std.testing.expectEqual(@as(u32, 3), try r.ue());
    try std.testing.expectEqual(@as(u32, 4), try r.ue());
    try std.testing.expectEqual(@as(i32, 1), try r.se());
    try std.testing.expectEqual(@as(i32, -1), try r.se());
}

test "emulation prevention" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const nal = try parseNal(arena.allocator(), &.{ 0x42, 0x01, 0x00, 0x00, 0x03, 0x01, 0x00, 0x00, 0x03 });
    try std.testing.expectEqual(NalType.sps, nal.type);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x01, 0x00, 0x00 }, nal.rbsp);
    // removed 03s sit at payload offsets 2 and 6; offset 5 has one removal before it
    try std.testing.expectEqual(@as(usize, 4), nal.rbspOffset(5));
}
