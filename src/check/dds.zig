//! DDS check: "DDS ", the 124-byte header, non-zero dimensions, no volume
//! textures, a DX10 extension header (2D textures only) when its FourCC
//! says so, and data after the header(s). The pixel format itself is
//! resolved by `Image.Texture`; here it only counts for the size estimate.
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

const header_len = 124;

pub fn sniff(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "DDS ");
}

pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth) Error!Info {
    _ = depth;
    if (!sniff(data)) return error.UnknownFormat;
    if (data.len < 4 + header_len) return error.Truncated;
    const hdr = data[4..][0..header_len];
    if (std.mem.readInt(u32, hdr[0..4], .little) != header_len) return error.InvalidHeader;
    const h = std.mem.readInt(u32, hdr[8..12], .little);
    const w = std.mem.readInt(u32, hdr[12..16], .little);
    if (std.mem.readInt(u32, hdr[20..24], .little) > 1) return error.UnsupportedFeature; // volume
    const mips = @max(1, std.mem.readInt(u32, hdr[24..28], .little));
    if (mips > 32) return error.InvalidHeader;
    try limits.admit(w, h);
    const faces: u64 = if (std.mem.readInt(u32, hdr[108..112], .little) & 0x200 != 0) 6 else 1;
    var layers: u64 = 1;
    var data_at: usize = 4 + header_len;
    if (std.mem.eql(u8, hdr[80..84], "DX10")) {
        if (data.len < data_at + 20) return error.Truncated;
        const x = data[data_at..][0..20];
        if (std.mem.readInt(u32, x[4..8], .little) != 3) return error.UnsupportedFeature; // not TEXTURE2D
        layers = @max(1, std.mem.readInt(u32, x[12..16], .little));
        data_at += 20;
    }
    if (data_at >= data.len) return error.MissingImageData;
    return .{
        .format = .dds,
        .width = w,
        .height = h,
        .channels = 4,
        .bits = 8,
        // Every image of the base level decoded to RGBA8, plus the mip chain (4/3).
        .decode_bytes = root.mul(root.mul(@as(u64, w) * h * 4, faces * layers), 4) / 3,
    };
}

test "dds header" {
    const t = std.testing;
    var buf: [4 + header_len + 16]u8 = @splat(0);
    @memcpy(buf[0..4], "DDS ");
    std.mem.writeInt(u32, buf[4..8], header_len, .little);
    std.mem.writeInt(u32, buf[12..16], 8, .little); // height
    std.mem.writeInt(u32, buf[16..20], 16, .little); // width
    const i = try root.check(&buf, .{});
    try t.expectEqual(@as(u32, 16), i.width);
    try t.expectEqual(@as(u32, 8), i.height);
    try t.expectError(error.MissingImageData, root.check(buf[0 .. 4 + header_len], .{}));
    std.mem.writeInt(u32, buf[24..28], 4, .little); // depth
    try t.expectError(error.UnsupportedFeature, root.check(&buf, .{}));
}
