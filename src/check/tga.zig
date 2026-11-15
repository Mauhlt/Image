//! TGA check. TGA has no signature: `detect` only recognises a TGA 2.0
//! file by its footer; any TGA can be checked with `checkAs(.tga, ...)`.
//! Image type (colour-mapped, true-colour, gray, each optionally RLE),
//! colour map type, pixel and colour-map depths Image decodes, non-zero
//! dimensions, the ID and colour map inside the file, and - for
//! uncompressed images - the whole pixel array present.
const std = @import("std");
const root = @import("root.zig");
const Error = root.Error;
const Info = root.Info;

const header_len = 18;
const footer = "TRUEVISION-XFILE.\x00";

pub fn sniff(data: []const u8) bool {
    return data.len >= header_len + 26 and std.mem.eql(u8, data[data.len - footer.len ..], footer);
}

pub fn check(data: []const u8, limits: root.Limits, depth: root.Depth) Error!Info {
    if (data.len < header_len) return error.Truncated;
    const cmap_type = data[1];
    const image_type = data[2];
    const cmap_len = std.mem.readInt(u16, data[5..7], .little);
    const cmap_depth = data[7];
    const w = std.mem.readInt(u16, data[12..14], .little);
    const h = std.mem.readInt(u16, data[14..16], .little);
    const bits = data[16];
    if (cmap_type > 1) return error.UnknownFormat;
    const base: u8 = switch (image_type) {
        1, 2, 3 => image_type,
        9, 10, 11 => image_type - 8,
        0 => return error.MissingImageData,
        else => return error.UnknownFormat,
    };
    var channels: u8 = 3;
    switch (base) {
        2 => switch (bits) {
            15, 16, 24 => {},
            32 => channels = 4,
            else => return error.InvalidBitDepth,
        },
        3 => switch (bits) {
            8 => channels = 1,
            16 => channels = 2,
            else => return error.InvalidBitDepth,
        },
        else => { // 1: colour-mapped
            if (cmap_type != 1 or cmap_len == 0) return error.InvalidHeader;
            if (bits != 8 and bits != 16) return error.InvalidBitDepth;
            switch (cmap_depth) {
                15, 16, 24 => {},
                32 => channels = 4,
                else => return error.InvalidBitDepth,
            }
        },
    }
    if (w == 0 or h == 0) return error.InvalidDimensions;
    try limits.admit(w, h);
    const px = @as(u64, w) * h;
    const info: Info = .{ .format = .tga, .width = w, .height = h, .channels = channels, .bits = @min(bits, 8), .decode_bytes = px * 4 };
    const cmap_bytes: u64 = if (cmap_type == 1) @as(u64, cmap_len) * ((@as(u64, cmap_depth) + 7) / 8) else 0;
    const pixels_at = header_len + @as(u64, data[0]) + cmap_bytes;
    if (pixels_at > data.len) return error.Truncated;
    if (depth == .header) return info;
    if (image_type < 9) {
        if (px * ((@as(u64, bits) + 7) / 8) > data.len - pixels_at) return error.Truncated;
    } else if (pixels_at == data.len) return error.MissingImageData;
    return info;
}

test "tga header" {
    const t = std.testing;
    // 2x1 true-colour 24-bit, uncompressed.
    const ok = "\x00\x00\x02" ++ @as([9]u8, @splat(0x00)) ++ "\x02\x00\x01\x00\x18\x00" ++ "\x01\x02\x03\x04\x05\x06";
    try t.expectEqual(@as(?root.Format, null), root.detect(ok));
    const i = try root.checkAs(.tga, ok, .{});
    try t.expectEqual(@as(u32, 2), i.width);
    try t.expectEqual(@as(u32, 1), i.height);
    try t.expectError(error.Truncated, root.checkAs(.tga, ok[0 .. ok.len - 1], .{}));
    var bad = ok.*;
    bad[16] = 12;
    try t.expectError(error.InvalidBitDepth, root.checkAs(.tga, &bad, .{}));
    bad = ok.*;
    bad[2] = 1; // colour-mapped without a map
    try t.expectError(error.InvalidHeader, root.checkAs(.tga, &bad, .{}));
    // With a 2.0 footer it is detected.
    const v2 = ok ++ @as([8]u8, @splat(0x00)) ++ footer;
    try t.expectEqual(root.Format.tga, root.detect(v2).?);
}
