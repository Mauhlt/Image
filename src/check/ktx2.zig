//! KTX 2 check: the identifier, the 80-byte header, non-zero width (a 1D
//! texture has height 0, reported as 1), no 3D textures, 1 or 6 faces,
//! a sane level count, and every level's data inside the file.
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

pub const identifier = [12]u8{ 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, '\r', '\n', 0x1A, '\n' };
const header_len = 80;
const level_len = 24;

pub fn sniff(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..12], &identifier);
}

fn u32At(d: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, d[off..][0..4], .little);
}

pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth) Error!Info {
    if (!sniff(data)) return error.UnknownFormat;
    if (data.len < header_len) return error.Truncated;
    const w = u32At(data, 20);
    const h = @max(1, u32At(data, 24));
    if (w == 0) return error.InvalidDimensions;
    if (u32At(data, 28) > 1) return error.UnsupportedFeature; // 3D
    const layers: u64 = @max(1, u32At(data, 32));
    const faces = u32At(data, 36);
    if (faces != 1 and faces != 6) return error.InvalidHeader;
    const levels = @max(1, u32At(data, 40));
    if (levels > 32) return error.InvalidHeader;
    try limits.admit(w, h);
    if (data.len - header_len < @as(u64, levels) * level_len) return error.Truncated;
    const info: Info = .{
        .format = .ktx2,
        .width = w,
        .height = h,
        .channels = 4,
        .bits = 8,
        .decode_bytes = root.mul(root.mul(@as(u64, w) * h * 4, layers * faces), 4) / 3,
    };
    if (depth == .header) return info;
    for (0..levels) |i| {
        const e = data[header_len + i * level_len ..][0..level_len];
        const off = std.mem.readInt(u64, e[0..8], .little);
        const len = std.mem.readInt(u64, e[8..16], .little);
        if (off > data.len or len > data.len - off) return error.Truncated;
    }
    return info;
}

test "ktx2 header" {
    const t = std.testing;
    var buf: [header_len + level_len + 4]u8 = @splat(0);
    @memcpy(buf[0..12], &identifier);
    std.mem.writeInt(u32, buf[20..24], 4, .little);
    std.mem.writeInt(u32, buf[24..28], 4, .little);
    std.mem.writeInt(u32, buf[36..40], 1, .little);
    std.mem.writeInt(u64, buf[header_len..][0..8], header_len + level_len, .little);
    std.mem.writeInt(u64, buf[header_len + 8 ..][0..8], 4, .little);
    const i = try root.check(&buf, .{});
    try t.expectEqual(@as(u32, 4), i.width);
    try t.expectError(error.Truncated, root.check(buf[0 .. buf.len - 1], .{}));
    std.mem.writeInt(u32, buf[36..40], 2, .little);
    try t.expectError(error.InvalidHeader, root.check(&buf, .{}));
}
