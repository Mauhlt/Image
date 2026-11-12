//! JPEG / JPEG-LS check: SOI, then every marker segment's length up to the
//! first scan (full) or the frame header (header), and the frame header's
//! fields against what Image decodes:
//!   SOF0/1/2 (baseline, extended, progressive): 8-bit, 1 or 3 components,
//!     sampling factors 1..4, quantisation table ids 0..3, height in the frame;
//!   SOF3 (lossless): 2..16 bits, 1 or 3 components, height in the frame or
//!     in a DNL segment after the first scan;
//!   SOF55 (JPEG-LS, `.jls`): the same, components interleaved 1x1.
//! Arithmetic coding and hierarchical frames are `UnsupportedFeature`.
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

pub fn sniff(data: []const u8) bool {
    return data.len >= 3 and data[0] == 0xFF and data[1] == 0xD8 and data[2] == 0xFF;
}

/// .jls if the first frame header is SOF55 (JPEG-LS), else .jpg. Walks the
/// segments before the frame (malformed ones end the walk: .jpg).
pub fn sniffFormat(data: []const u8) root.Format {
    var pos: usize = 2;
    while (pos + 4 <= data.len and data[pos] == 0xFF) {
        const m = data[pos + 1];
        if (m == 0xF7) return .jls;
        if (m == 0xDA or (m >= 0xC0 and m <= 0xCF and m != 0xC4 and m != 0xC8 and m != 0xCC)) return .jpg;
        if (m == 0xFF or standalone(m)) {
            pos += if (m == 0xFF) 1 else 2;
            continue;
        }
        pos += 2 + @as(usize, std.mem.readInt(u16, data[pos + 2 ..][0..2], .big));
    }
    return .jpg;
}

const Frame = struct { marker: u8, precision: u8, width: u16, height: u16, nc: u8 };

fn standalone(m: u8) bool {
    return m == 0x01 or (m >= 0xD0 and m <= 0xD8);
}

/// Offset of the marker ending the entropy-coded data from `start`
/// (stuffed 0xFF00 and RSTn skipped), or data.len.
fn entropyEnd(data: []const u8, start: usize) usize {
    var i = start;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] != 0xFF) continue;
        const m = data[i + 1];
        if (m == 0x00 or m == 0xFF or (m >= 0xD0 and m <= 0xD7)) continue;
        return i;
    }
    return data.len;
}

fn parseFrame(m: u8, seg: []const u8) Error!Frame {
    if (seg.len < 6) return error.InvalidChunk;
    const f: Frame = .{
        .marker = m,
        .precision = seg[0],
        .height = std.mem.readInt(u16, seg[1..3], .big),
        .width = std.mem.readInt(u16, seg[3..5], .big),
        .nc = seg[5],
    };
    if (seg.len < 6 + @as(usize, f.nc) * 3) return error.InvalidChunk;
    if (f.width == 0) return error.InvalidDimensions;
    switch (m) {
        0xC0, 0xC1, 0xC2 => {
            if (f.precision != 8) return error.InvalidBitDepth;
            if (f.nc != 1 and f.nc != 3) return if (f.nc == 0) error.InvalidHeader else error.UnsupportedFeature;
            if (f.height == 0) return error.UnsupportedFeature; // DNL
            for (0..f.nc) |i| {
                const c = seg[6 + 3 * i ..][0..3];
                const h = c[1] >> 4;
                const v = c[1] & 0xF;
                if (h == 0 or h > 4 or v == 0 or v > 4 or c[2] > 3) return error.InvalidHeader;
            }
        },
        0xC3, 0xF7 => {
            if (f.precision < 2 or f.precision > 16) return error.InvalidBitDepth;
            if (f.nc != 1 and f.nc != 3) return if (f.nc == 0) error.InvalidHeader else error.UnsupportedFeature;
            if (f.nc > 1) for (0..f.nc) |i| if (seg[7 + 3 * i] != 0x11) return error.UnsupportedFeature;
        },
        else => unreachable,
    }
    return f;
}

/// Height from the DNL segment that follows the first scan.
fn dnlHeight(data: []const u8, sos_end: usize) Error!u16 {
    const end = entropyEnd(data, sos_end);
    if (end + 2 > data.len) return error.Truncated;
    if (data[end + 1] != 0xDC) return error.InvalidDimensions;
    if (end + 6 > data.len) return error.Truncated;
    const h = std.mem.readInt(u16, data[end + 4 ..][0..2], .big);
    if (h == 0) return error.InvalidDimensions;
    return h;
}

/// `want`: .jpg or .jls (an SOF55 frame is JPEG-LS, anything else JPEG).
pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth, want: root.Format) Error!Info {
    if (data.len < 2 or data[0] != 0xFF or data[1] != 0xD8) return error.UnknownFormat;
    var pos: usize = 2;
    var frame: ?Frame = null;
    var segments: u32 = 0;
    while (true) {
        if (pos >= data.len) return if (frame == null) error.Truncated else error.MissingImageData;
        if (data[pos] != 0xFF) return error.InvalidChunk;
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) return error.Truncated;
        const m = data[pos];
        pos += 1;
        segments += 1;
        if (segments > limits.max_chunks) return error.TooManyChunks;
        if (m == 0xD9) return error.MissingImageData; // EOI before any scan
        if (standalone(m)) continue;
        const len = try root.int(u16, data, pos, .big);
        if (len < 2) return error.InvalidChunk;
        if (data.len - pos < len) return error.Truncated;
        const seg = data[pos + 2 .. pos + len];
        pos += len;
        switch (m) {
            0xC0, 0xC1, 0xC2, 0xC3, 0xF7 => {
                if (frame != null) return error.InvalidChunkOrder;
                const f = try parseFrame(m, seg);
                const format: root.Format = if (m == 0xF7) .jls else .jpg;
                if (format != want) return error.UnsupportedFeature;
                if (f.height != 0) try limits.admit(f.width, f.height);
                frame = f;
                if (depth == .header and f.height != 0) return info(f, f.height);
            },
            0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => return error.UnsupportedFeature,
            0xDA => {
                const f = frame orelse return error.InvalidChunkOrder;
                if (seg.len < 1 or seg[0] == 0 or seg[0] > f.nc or seg.len < 1 + 2 * @as(usize, seg[0]) + 3) return error.InvalidChunk;
                const h = if (f.height != 0) f.height else try dnlHeight(data, pos);
                return info(f, h);
            },
            else => {},
        }
    }
}

fn info(f: Frame, height: u16) Info {
    const px: u64 = @as(u64, f.width) * height;
    // Padded to whole 16x16 MCUs; 1 byte per sample per plane, plus i16
    // coefficients for a progressive frame, or u16 samples for lossless.
    const padded = ((@as(u64, f.width) + 15) & ~@as(u64, 15)) * ((@as(u64, height) + 15) & ~@as(u64, 15));
    const work: u64 = switch (f.marker) {
        0xC2 => padded * f.nc * 3,
        0xC3, 0xF7 => px * f.nc * 2,
        else => padded * f.nc,
    };
    return .{
        .format = if (f.marker == 0xF7) .jls else .jpg,
        .width = f.width,
        .height = height,
        .channels = f.nc,
        .bits = f.precision,
        .decode_bytes = work + px * (if (f.nc == 1 and f.precision > 8) @as(u64, 2) else f.nc),
    };
}

const testing = std.testing;

test "jpeg frames" {
    const sof = "\xFF\xD8\xFF\xC0\x00\x11\x08\x00\x10\x00\x20\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01";
    const sos = "\xFF\xDA\x00\x0C\x03\x01\x00\x02\x11\x03\x11\x00\x3F\x00";
    const file = sof ++ sos ++ "\x12\x34\xFF\x00\xFF\xD9";
    const i = try root.check(file, .{});
    try testing.expectEqual(root.Format.jpg, i.format);
    try testing.expectEqual(@as(u32, 32), i.width);
    try testing.expectEqual(@as(u32, 16), i.height);
    try testing.expectEqual(@as(u8, 3), i.channels);
    _ = try root.checkHeader(sof, .{});
    try testing.expectError(error.MissingImageData, root.check(sof, .{}));
    try testing.expectError(error.MissingImageData, root.check(sof ++ "\xFF\xD9", .{}));
    try testing.expectError(error.ImageTooLarge, root.check(file, .{ .max_width = 31 }));
    try testing.expectError(error.UnsupportedFeature, root.checkAs(.jls, file, .{}));
    // Arithmetic coding.
    var ari = file.*;
    ari[3] = 0xC9;
    try testing.expectError(error.UnsupportedFeature, root.check(&ari, .{}));
    // 12-bit baseline.
    var deep = file.*;
    deep[6] = 12;
    try testing.expectError(error.InvalidBitDepth, root.check(&deep, .{}));
    // Segment length past the end.
    try testing.expectError(error.Truncated, root.check(sof[0..10], .{}));
    // Every truncation fails cleanly.
    for (0..file.len) |n| _ = root.check(file[0..n], .{}) catch {};
}

test "lossless and JPEG-LS with DNL" {
    // SOF3, 12-bit, 1 component, height 0 (in DNL).
    const sof3 = "\xFF\xD8\xFF\xC3\x00\x0B\x0C\x00\x00\x00\x07\x01\x01\x11\x00";
    const sos = "\xFF\xDA\x00\x08\x01\x01\x00\x01\x00\x00";
    const dnl = "\xFF\xDC\x00\x04\x00\x05";
    const file = sof3 ++ sos ++ "\xAA\xBB" ++ dnl ++ "\xFF\xD9";
    const i = try root.check(file, .{});
    try testing.expectEqual(@as(u32, 7), i.width);
    try testing.expectEqual(@as(u32, 5), i.height);
    try testing.expectEqual(@as(u8, 12), i.bits);
    try testing.expectError(error.InvalidDimensions, root.check(sof3 ++ sos ++ "\xAA\xFF\xD9", .{}));
    var ls = file.*;
    ls[3] = 0xF7;
    try testing.expectEqual(root.Format.jls, root.detect(&ls).?);
    try testing.expectEqual(root.Format.jls, (try root.check(&ls, .{})).format);
    try testing.expectError(error.UnsupportedFeature, root.checkAs(.jpg, &ls, .{}));
}
