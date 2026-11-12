//! BMP / DIB check: "BM", a known DIB header size (OS/2 core, or
//! BITMAPINFOHEADER and its V2..V5 extensions), dimensions (negative height
//! = top-down), one plane, a bit count and compression Image decodes, the
//! pixel data offset inside the file, and - for uncompressed images - the
//! whole pixel array present.
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

const file_hdr = 14;
const core_hdr = 12;
const info_hdr = 40;

pub fn sniff(data: []const u8) bool {
    if (data.len < file_hdr + 4 or !std.mem.eql(u8, data[0..2], "BM")) return false;
    const size = std.mem.readInt(u32, data[14..18], .little);
    return size == core_hdr or (size >= info_hdr and size <= 255);
}

pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth) Error!Info {
    if (data.len < 2 or !std.mem.eql(u8, data[0..2], "BM")) return error.UnknownFormat;
    const dib_size = try root.int(u32, data, 14, .little);
    if (dib_size != core_hdr and dib_size < info_hdr) return error.InvalidHeader;
    if (data.len - file_hdr < dib_size) return error.Truncated;
    const dib = data[file_hdr..][0..dib_size];
    const core = dib_size == core_hdr;
    const raw_w: i64 = if (core) std.mem.readInt(u16, dib[4..6], .little) else std.mem.readInt(i32, dib[4..8], .little);
    const raw_h: i64 = if (core) std.mem.readInt(u16, dib[6..8], .little) else std.mem.readInt(i32, dib[8..12], .little);
    if (raw_w <= 0 or raw_h == 0 or raw_h == std.math.minInt(i32)) return error.InvalidDimensions;
    const w: u32 = @intCast(raw_w);
    const h: u32 = @intCast(@abs(raw_h));
    if (std.mem.readInt(u16, if (core) dib[8..10] else dib[12..14], .little) != 1) return error.InvalidHeader;
    const bits = std.mem.readInt(u16, if (core) dib[10..12] else dib[14..16], .little);
    switch (bits) {
        1, 2, 4, 8, 16, 24, 32 => {},
        else => return error.InvalidBitDepth,
    }
    const compression: u32 = if (core) 0 else std.mem.readInt(u32, dib[16..20], .little);
    const ok = switch (compression) {
        0 => true,
        1 => bits == 8, // RLE8
        2 => bits == 4, // RLE4
        3, 6 => bits == 16 or bits == 32, // (alpha) bitfields
        4, 5 => return error.UnsupportedFeature, // embedded JPEG / PNG
        else => return error.InvalidCompression,
    };
    if (!ok) return error.InvalidCompression;
    try limits.admit(w, h);

    const has_alpha = !core and (compression == 6 or (compression == 3 and dib_size >= 56 and std.mem.readInt(u32, dib[52..56], .little) != 0));
    const rle = compression == 1 or compression == 2;
    var info: Info = .{
        .format = .bmp,
        .width = w,
        .height = h,
        .channels = if (has_alpha) 4 else 3,
        .bits = @intCast(@min(bits, 8)),
        .decode_bytes = root.mul(@as(u64, w) * h, if (rle) 6 else 4) + @as(u64, w) * 4,
    };
    if (bits == 32 and compression == 0) info.channels = 3;
    if (depth == .header) return info;

    const offset = std.mem.readInt(u32, data[10..14], .little);
    if (offset < file_hdr + dib_size or offset > data.len) return error.InvalidHeader;
    if (!rle) {
        const stride = ((@as(u64, w) * bits + 31) / 32) * 4;
        if (root.mul(stride, h) > data.len - offset) return error.Truncated;
    } else if (offset == data.len) return error.MissingImageData;
    return info;
}

const testing = std.testing;

fn make(w: i32, h: i32, bits: u16, compression: u32, body_len: usize, buf: []u8) []u8 {
    @memset(buf, 0);
    const off = file_hdr + info_hdr;
    @memcpy(buf[0..2], "BM");
    std.mem.writeInt(u32, buf[2..6], @intCast(off + body_len), .little);
    std.mem.writeInt(u32, buf[10..14], off, .little);
    std.mem.writeInt(u32, buf[14..18], info_hdr, .little);
    std.mem.writeInt(i32, buf[18..22], w, .little);
    std.mem.writeInt(i32, buf[22..26], h, .little);
    std.mem.writeInt(u16, buf[26..28], 1, .little);
    std.mem.writeInt(u16, buf[28..30], bits, .little);
    std.mem.writeInt(u32, buf[30..34], compression, .little);
    return buf[0 .. off + body_len];
}

test "bmp headers" {
    var buf: [256]u8 = undefined;
    // 5x3 24-bit: rows of 15 bytes padded to 16.
    const ok = make(5, -3, 24, 0, 48, &buf);
    try testing.expectEqual(root.Format.bmp, root.detect(ok).?);
    const i = try root.check(ok, .{});
    try testing.expectEqual(@as(u32, 5), i.width);
    try testing.expectEqual(@as(u32, 3), i.height);
    try testing.expectError(error.Truncated, root.check(ok[0 .. ok.len - 1], .{}));
    _ = try root.checkHeader(ok[0 .. ok.len - 1], .{});
    try testing.expectError(error.InvalidDimensions, root.check(make(0, 3, 24, 0, 48, &buf), .{}));
    try testing.expectError(error.InvalidBitDepth, root.check(make(5, 3, 12, 0, 48, &buf), .{}));
    try testing.expectError(error.InvalidCompression, root.check(make(5, 3, 24, 1, 48, &buf), .{}));
    try testing.expectError(error.UnsupportedFeature, root.check(make(5, 3, 24, 4, 48, &buf), .{}));
    try testing.expectError(error.ImageTooLarge, root.check(make(100000, 3, 24, 0, 48, &buf), .{}));
}
