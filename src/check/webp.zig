//! WebP check: RIFF/WEBP container, every chunk inside the RIFF size,
//! VP8X (no animation), then the image bitstream's header: VP8L signature,
//! version 0 and its 14-bit dimensions, or VP8's key-frame start code and
//! dimensions (which must match the VP8X canvas when there is one).
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

pub fn sniff(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth) Error!Info {
    _ = depth; // the header is the structure: the walk stops at the bitstream
    if (!sniff(data)) return error.UnknownFormat;
    const riff = std.mem.readInt(u32, data[4..8], .little);
    // A RIFF size past the data's end is clamped to it (decoders do too).
    const end: usize = @intCast(@min(@as(u64, data.len), @as(u64, riff) + 8));
    var pos: usize = 12;
    var canvas: ?[2]u32 = null;
    var alpha = false;
    var chunks: u32 = 0;
    while (pos < end) {
        if (end - pos < 8) return error.Truncated;
        chunks += 1;
        if (chunks > limits.max_chunks) return error.TooManyChunks;
        const tag = data[pos..][0..4];
        const len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const body_at = pos + 8;
        if (len > end - body_at) return error.Truncated;
        const body = data[body_at..][0..len];
        pos = body_at + len + (len & 1);
        if (std.mem.eql(u8, tag, "VP8X")) {
            if (len < 10) return error.InvalidChunk;
            if (body[0] & 0x02 != 0) return error.UnsupportedFeature; // animation
            alpha = body[0] & 0x10 != 0;
            const w = (@as(u32, std.mem.readInt(u24, body[4..7], .little))) + 1;
            const h = (@as(u32, std.mem.readInt(u24, body[7..10], .little))) + 1;
            try limits.admit(w, h);
            canvas = .{ w, h };
        } else if (std.mem.eql(u8, tag, "VP8L")) {
            if (len < 5 or body[0] != 0x2F) return error.InvalidHeader;
            const bits = std.mem.readInt(u32, body[1..5], .little);
            if (bits >> 29 != 0) return error.UnsupportedFeature; // version
            const w = (bits & 0x3FFF) + 1;
            const h = ((bits >> 14) & 0x3FFF) + 1;
            return finish(limits, canvas, w, h, (bits >> 28) & 1 != 0, true);
        } else if (std.mem.eql(u8, tag, "VP8 ")) {
            if (len < 10) return error.InvalidChunk;
            if (body[0] & 1 != 0) return error.InvalidHeader; // not a key frame
            if (!std.mem.eql(u8, body[3..6], "\x9D\x01\x2A")) return error.InvalidHeader;
            const w = std.mem.readInt(u16, body[6..8], .little) & 0x3FFF;
            const h = std.mem.readInt(u16, body[8..10], .little) & 0x3FFF;
            return finish(limits, canvas, w, h, alpha, false);
        } else if (std.mem.eql(u8, tag, "ANIM") or std.mem.eql(u8, tag, "ANMF")) {
            return error.UnsupportedFeature;
        }
        // ALPH, ICCP, EXIF, XMP, unknown: skipped
    }
    return error.MissingImageData;
}

fn finish(limits: root.Limits, canvas: ?[2]u32, w: u32, h: u32, alpha: bool, lossless: bool) Error!Info {
    try limits.admit(w, h);
    if (canvas) |c| if (c[0] != w or c[1] != h) return error.InvalidHeader;
    const px = @as(u64, w) * h;
    return .{
        .format = .webp,
        .width = w,
        .height = h,
        .channels = if (alpha) 4 else 3,
        .bits = 8,
        // Lossless: ARGB words plus transform buffers; lossy: YUV planes
        // and an alpha plane. Then the RGB(A) output.
        .decode_bytes = px * (if (lossless) @as(u64, 8) else 3) + px * 4,
    };
}

const testing = std.testing;

test "webp containers" {
    // Lossless 3x2, alpha bit set.
    const bits: u32 = (2) | (1 << 14) | (1 << 28);
    var vp8l: [5]u8 = undefined;
    vp8l[0] = 0x2F;
    std.mem.writeInt(u32, vp8l[1..5], bits, .little);
    const ll = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00" ++ vp8l ++ "\x00";
    const i = try root.check(ll, .{});
    try testing.expectEqual(root.Format.webp, i.format);
    try testing.expectEqual(@as(u32, 3), i.width);
    try testing.expectEqual(@as(u32, 2), i.height);
    try testing.expectEqual(@as(u8, 4), i.channels);
    try testing.expectError(error.Truncated, root.check(ll[0..22], .{}));
    // Lossy 16x8 key frame.
    const lossy = "RIFF\x16\x00\x00\x00WEBPVP8 \x0A\x00\x00\x00\x10\x02\x00\x9D\x01\x2A\x10\x00\x08\x00";
    const j = try root.check(lossy, .{});
    try testing.expectEqual(@as(u32, 16), j.width);
    try testing.expectEqual(@as(u32, 8), j.height);
    var bad = lossy.*;
    bad[23] = 0;
    try testing.expectError(error.InvalidHeader, root.check(&bad, .{}));
    // Animated.
    const anim = "RIFF\x16\x00\x00\x00WEBPVP8X\x0A\x00\x00\x00\x02\x00\x00\x00\x0F\x00\x00\x07\x00\x00";
    try testing.expectError(error.UnsupportedFeature, root.check(anim, .{}));
    try testing.expectError(error.MissingImageData, root.check("RIFF\x04\x00\x00\x00WEBP", .{}));
}
