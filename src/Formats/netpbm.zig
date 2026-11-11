//! Shared Netpbm (PGM / PPM) reader + writer.
//!   P2 / P5 = graymap (1 channel), ASCII / binary
//!   P3 / P6 = pixmap  (3 channels), ASCII / binary
//! Header: magic, width, height, maxval separated by whitespace; '#' starts a comment.
//! maxval may be 1..65535 (2 bytes/sample above 255); samples are rescaled to 8-bit.
const std = @import("std");
const Error = @import("error.zig").Error;
const Image = @import("../root.zig");
const Info = @import("../info.zig");
const PixelTag = @import("../Colors/pixels.zig").PixelTag;

pub const Magic = enum { P2, P3, P5, P6 };

pub const Header = struct {
    magic: Magic,
    width: u32,
    height: u32,
    max_val: u16,
    /// offset of the first raster byte (binary) or first sample token (ascii)
    data_start: usize,

    pub fn channels(self: Header) u8 {
        return switch (self.magic) {
            .P2, .P5 => 1,
            .P3, .P6 => 3,
        };
    }

    pub fn isAscii(self: Header) bool {
        return self.magic == .P2 or self.magic == .P3;
    }
};

fn skipWhitespaceAndComments(data: []const u8, pos: usize) usize {
    var i = pos;
    while (i < data.len) {
        if (data[i] == '#') {
            while (i < data.len and data[i] != '\n') i += 1;
        } else if (std.ascii.isWhitespace(data[i])) {
            i += 1;
        } else break;
    }
    return i;
}

/// Parses the next unsigned integer token starting at `pos.*`.
fn readUint(data: []const u8, pos: *usize) Error!u32 {
    var i = skipWhitespaceAndComments(data, pos.*);
    const start = i;
    var value: u64 = 0;
    while (i < data.len and std.ascii.isDigit(data[i])) : (i += 1) {
        value = value * 10 + (data[i] - '0');
        if (value > std.math.maxInt(u32)) return Error.InvalidNum;
    }
    if (i == start) return if (i >= data.len) Error.UnexpectedEndOfData else Error.InvalidToken;
    pos.* = i;
    return @intCast(value);
}

pub fn decodeHeader(data: []const u8) Error!Header {
    if (data.len < 2) return Error.UnexpectedEndOfData;
    const magic = std.meta.stringToEnum(Magic, data[0..2]) orelse return Error.UnexpectedSignature;
    var pos: usize = 2;
    const width = try readUint(data, &pos);
    const height = try readUint(data, &pos);
    const max_val = try readUint(data, &pos);
    if (width == 0 or height == 0) return Error.InvalidDimensions;
    if (max_val == 0 or max_val > 0xFFFF) return Error.InvalidMaxVal;
    // binary rasters start after exactly one whitespace byte
    if (pos >= data.len or !std.ascii.isWhitespace(data[pos])) return Error.UnexpectedEndOfData;
    return .{
        .magic = magic,
        .width = width,
        .height = height,
        .max_val = @intCast(max_val),
        .data_start = pos + 1,
    };
}

pub fn info(data: []const u8) Error!Info {
    const hdr = try decodeHeader(data);
    const tag: PixelTag = if (hdr.channels() == 1) .g else .rgb;
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(data: []const u8, inf: Info, out: []u8) Error!void {
    const hdr = try decodeHeader(data);
    const n_samples = @as(usize, hdr.width) * hdr.height * hdr.channels();
    if (out.len != n_samples or inf.tag.bytesPerPixel() != hdr.channels()) return Error.InvalidDataLen;
    const max: u32 = hdr.max_val;

    if (hdr.isAscii()) {
        var pos = hdr.data_start;
        for (out) |*o| {
            const v = try readUint(data, &pos);
            if (v > max) return Error.InvalidNum;
            o.* = scale(v, max);
        }
        return;
    }

    const raster = data[hdr.data_start..];
    if (max <= 255) {
        if (raster.len < n_samples) return Error.UnexpectedEndOfData;
        if (max == 255) {
            @memcpy(out, raster[0..n_samples]);
        } else for (out, raster[0..n_samples]) |*o, v| {
            o.* = scale(v, max);
        }
    } else {
        if (raster.len < n_samples * 2) return Error.UnexpectedEndOfData;
        for (out, 0..) |*o, i| o.* = scale(std.mem.readInt(u16, raster[i * 2 ..][0..2], .big), max);
    }
}

fn scale(v: u32, max: u32) u8 {
    return @intCast(@min(255, (v * 255 + max / 2) / max));
}

/// Binary (P5 / P6), maxval 255.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator, tag: PixelTag) !void {
    std.debug.assert(tag == .g or tag == .rgb);
    const converted = if (std.meta.activeTag(img.pixels) == tag) null else try img.pixels.convertV(tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const magic = if (tag == .g) "P5" else "P6";
    try w.print("{s}\n{} {}\n255\n", .{ magic, img.width, img.height });
    try w.writeAll((converted orelse img.pixels).asBytes());
}

test "netpbm ascii with comments" {
    const src = "P2\n# comment\n3 2 # trailing\n15\n0 15 7\n# mid\n1 2 3\n";
    const inf = try info(src);
    try std.testing.expectEqual(@as(u32, 3), inf.width);
    var out: [6]u8 = undefined;
    try decodeInto(src, inf, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 119, 17, 34, 51 }, &out);
}

test "netpbm 16-bit binary" {
    const src = "P6 1 1 65535\n" ++ [_]u8{ 0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00 };
    const inf = try info(src);
    var out: [3]u8 = undefined;
    try decodeInto(src, inf, &out);
    try std.testing.expectEqualSlices(u8, &.{ 255, 128, 0 }, &out);
}
