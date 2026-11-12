//! Netpbm check: P1..P6 headers (magic, width, height, maxval except for
//! PBM, separated by whitespace and # comments, then one whitespace byte)
//! and P7 / PAM headers (WIDTH HEIGHT DEPTH MAXVAL [TUPLTYPE] ENDHDR lines),
//! with the rules Image decodes by: maxval 1..65535, PAM depth 1..4
//! matching its tuple type. Binary forms (P4, P5, P6, P7) must hold the
//! whole raster; ASCII forms must have at least one sample.
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

pub fn sniff(data: []const u8) ?root.Format {
    if (data.len < 3 or data[0] != 'P' or !std.ascii.isWhitespace(data[2])) return null;
    return switch (data[1]) {
        '1', '4' => .pbm,
        '2', '5' => .pgm,
        '3', '6' => .ppm,
        '7' => .pam,
        else => null,
    };
}

fn skipSpace(data: []const u8, pos: usize) usize {
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

fn readUint(data: []const u8, pos: *usize) Error!u32 {
    var i = skipSpace(data, pos.*);
    const start = i;
    var v: u64 = 0;
    while (i < data.len and std.ascii.isDigit(data[i])) : (i += 1) {
        v = v * 10 + (data[i] - '0');
        if (v > std.math.maxInt(u32)) return error.InvalidHeader;
    }
    if (i == start) return if (i >= data.len) error.Truncated else error.InvalidHeader;
    pos.* = i;
    return @intCast(v);
}

const Pam = struct { w: u32, h: u32, depth: u32, max: u32, start: usize };

fn pamHeader(data: []const u8) Error!Pam {
    var w: ?u32 = null;
    var h: ?u32 = null;
    var d: ?u32 = null;
    var m: ?u32 = null;
    var tuple: []const u8 = "";
    var pos: usize = 2;
    while (true) {
        const eol = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse return error.Truncated;
        const line = std.mem.trim(u8, data[pos..eol], &std.ascii.whitespace);
        pos = eol + 1;
        if (line.len == 0 or line[0] == '#') continue;
        const key_end = std.mem.indexOfAny(u8, line, &std.ascii.whitespace) orelse line.len;
        const key = line[0..key_end];
        const value = std.mem.trim(u8, line[key_end..], &std.ascii.whitespace);
        if (std.mem.eql(u8, key, "ENDHDR")) break;
        if (std.mem.eql(u8, key, "TUPLTYPE")) {
            tuple = value;
            continue;
        }
        const n = std.fmt.parseInt(u32, value, 10) catch return error.InvalidHeader;
        if (std.mem.eql(u8, key, "WIDTH")) {
            w = n;
        } else if (std.mem.eql(u8, key, "HEIGHT")) {
            h = n;
        } else if (std.mem.eql(u8, key, "DEPTH")) {
            d = n;
        } else if (std.mem.eql(u8, key, "MAXVAL")) {
            m = n;
        } else return error.InvalidHeader;
    }
    const depth = d orelse return error.InvalidHeader;
    const want: ?u32 = if (std.mem.eql(u8, tuple, "BLACKANDWHITE") or std.mem.eql(u8, tuple, "GRAYSCALE"))
        1
    else if (std.mem.eql(u8, tuple, "BLACKANDWHITE_ALPHA") or std.mem.eql(u8, tuple, "GRAYSCALE_ALPHA"))
        2
    else if (std.mem.eql(u8, tuple, "RGB"))
        3
    else if (std.mem.eql(u8, tuple, "RGB_ALPHA"))
        4
    else
        null;
    if (want) |n| {
        if (n != depth) return error.InvalidColorType;
    } else if (depth < 1 or depth > 4) return error.InvalidColorType;
    return .{
        .w = w orelse return error.InvalidHeader,
        .h = h orelse return error.InvalidHeader,
        .depth = depth,
        .max = m orelse return error.InvalidHeader,
        .start = pos,
    };
}

/// `want`: .pbm, .pgm, .ppm or .pam; the magic number must agree.
pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth, want: root.Format) Error!Info {
    const format = sniff(data) orelse return error.UnknownFormat;
    if (format != want) return error.UnknownFormat;
    const magic = data[1];
    var w: u32 = undefined;
    var h: u32 = undefined;
    var max: u32 = 1;
    var channels: u32 = 1;
    var start: usize = undefined;
    if (magic == '7') {
        const p = try pamHeader(data);
        w = p.w;
        h = p.h;
        max = p.max;
        channels = p.depth;
        start = p.start;
    } else {
        var pos: usize = 2;
        w = try readUint(data, &pos);
        h = try readUint(data, &pos);
        if (magic != '1' and magic != '4') max = try readUint(data, &pos);
        if (magic == '3' or magic == '6') channels = 3;
        // Exactly one whitespace byte (or a comment ending in a newline) before the raster.
        if (pos < data.len and data[pos] == '#') pos = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse return error.Truncated;
        if (pos >= data.len) return error.Truncated;
        if (!std.ascii.isWhitespace(data[pos])) return error.InvalidHeader;
        start = pos + 1;
    }
    if (w == 0 or h == 0) return error.InvalidDimensions;
    if (max == 0 or max > 0xFFFF) return error.InvalidBitDepth;
    try limits.admit(w, h);
    const bits: u8 = @intCast(std.math.log2_int(u32, max) + 1);
    const px = @as(u64, w) * h;
    const info: Info = .{
        .format = format,
        .width = w,
        .height = h,
        .channels = @intCast(channels),
        .bits = bits,
        .decode_bytes = px * channels * (if (channels == 1 and max > 255) @as(u64, 2) else 1),
    };
    if (depth == .header) return info;
    const raster: u64 = switch (magic) {
        '4' => ((@as(u64, w) + 7) / 8) * h,
        '5', '6', '7' => px * channels * (if (max > 255) @as(u64, 2) else 1),
        else => 1, // ASCII: at least one sample
    };
    if (raster > data.len - start) return error.Truncated;
    return info;
}

const testing = std.testing;

test "netpbm headers" {
    const ppm = "P6 # c\n3 2\n255\n" ++ @as([18]u8, @splat(0x01));
    const i = try root.check(ppm, .{});
    try testing.expectEqual(root.Format.ppm, i.format);
    try testing.expectEqual(@as(u32, 3), i.width);
    try testing.expectEqual(@as(u32, 2), i.height);
    try testing.expectEqual(@as(u8, 3), i.channels);
    try testing.expectError(error.Truncated, root.check(ppm[0 .. ppm.len - 1], .{}));
    _ = try root.checkHeader(ppm[0 .. ppm.len - 1], .{});
    try testing.expectError(error.UnknownFormat, root.checkAs(.pgm, ppm, .{}));

    const pbm = "P1\n2 2\n0 1\n1 0\n";
    try testing.expectEqual(root.Format.pbm, (try root.check(pbm, .{})).format);
    const pgm16 = "P5 1 1 65535\n\x12\x34";
    const g = try root.check(pgm16, .{});
    try testing.expectEqual(@as(u8, 16), g.bits);
    try testing.expectError(error.InvalidBitDepth, root.check("P5 1 1 0\n\x00", .{}));
    try testing.expectError(error.InvalidBitDepth, root.check("P5 1 1 70000\n\x00", .{}));
    try testing.expectError(error.InvalidDimensions, root.check("P5 0 1 255\n\x00", .{}));
    try testing.expectError(error.InvalidHeader, root.check("P5 x 1 255\n\x00", .{}));

    const pam = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" ++ @as([8]u8, @splat(0x00));
    const a = try root.check(pam, .{});
    try testing.expectEqual(root.Format.pam, a.format);
    try testing.expectEqual(@as(u8, 4), a.channels);
    const pam_bad = "P7\nWIDTH 2\nHEIGHT 1\nDEPTH 3\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n" ++ @as([8]u8, @splat(0x00));
    try testing.expectError(error.InvalidColorType, root.check(pam_bad, .{}));
    try testing.expectError(error.Truncated, root.check("P7\nWIDTH 2\n", .{}));
}
