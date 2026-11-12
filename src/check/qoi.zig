//! QOI check: "qoif", dimensions, channels 3 or 4, colourspace 0 or 1; the
//! full check also wants the 8-byte end marker (7 zeros and a 1).
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

const header_len = 14;
const end_marker = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub fn sniff(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "qoif");
}

pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth) Error!Info {
    if (!sniff(data)) return error.UnknownFormat;
    if (data.len < header_len) return error.Truncated;
    const w = std.mem.readInt(u32, data[4..8], .big);
    const h = std.mem.readInt(u32, data[8..12], .big);
    const channels = data[12];
    if (channels != 3 and channels != 4) return error.InvalidColorType;
    if (data[13] > 1) return error.InvalidHeader; // colourspace
    try limits.admit(w, h);
    const info: Info = .{
        .format = .qoi,
        .width = w,
        .height = h,
        .channels = channels,
        .bits = 8,
        .decode_bytes = @as(u64, w) * h * channels,
    };
    if (depth == .header) return info;
    if (data.len < header_len + end_marker.len) return error.MissingImageData;
    if (!std.mem.eql(u8, data[data.len - 8 ..], &end_marker)) return error.MissingEnd;
    return info;
}

test "qoi header" {
    const t = std.testing;
    const ok = "qoif\x00\x00\x00\x02\x00\x00\x00\x03\x04\x00" ++ "\xFE\x10\x20\x30" ++ end_marker;
    const i = try root.check(ok, .{});
    try t.expectEqual(@as(u32, 2), i.width);
    try t.expectEqual(@as(u32, 3), i.height);
    try t.expectEqual(@as(u8, 4), i.channels);
    try t.expectError(error.MissingEnd, root.check(ok[0 .. ok.len - 1], .{}));
    var bad = ok.*;
    bad[12] = 2;
    try t.expectError(error.InvalidColorType, root.check(&bad, .{}));
    bad = ok.*;
    bad[7] = 0;
    try t.expectError(error.InvalidDimensions, root.check(&bad, .{}));
}
