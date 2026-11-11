//! WebP. Lossless (VP8L) decode + encode, simple and extended (VP8X) containers.
//! Lossy (VP8) and animation are detected and rejected.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const Header = @import("header.zig");
const vp8l_decode = @import("decode.zig");
const vp8l_encode = @import("encode.zig");

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data);
    if (hdr.codec == .lossy) return Error.UnsupportedLossy;
    const tag: PixelTag = if (hdr.alpha) .rgba else .rgb;
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const hdr: Header = try .decode(data);
    if (hdr.codec == .lossy) return Error.UnsupportedLossy;
    if (hdr.width != inf.width or hdr.height != inf.height) return Error.InvalidDimensions;
    const n = @as(usize, hdr.width) * hdr.height;
    const argb = try scratch.alloc(u32, n);
    defer scratch.free(argb);
    try vp8l_decode.decodeArgb(scratch, hdr.bitstream, hdr.width, hdr.height, argb);
    switch (inf.tag) {
        .rgba => for (argb, 0..) |p, i| {
            out[i * 4 ..][0..4].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24) };
        },
        .rgb => for (argb, 0..) |p, i| {
            out[i * 3 ..][0..3].* = .{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) };
        },
        else => return Error.UnsupportedPixels,
    }
}

/// Lossless.
pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    if (img.width == 0 or img.height == 0 or img.width > 16384 or img.height > 16384) return Error.InvalidDimensions;
    const converted = if (img.pixels == .rgba) null else try img.pixels.convertV(.rgba, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const rgba = (converted orelse img.pixels).asBytes();

    const n = @as(usize, img.width) * img.height;
    const argb = try gpa.alloc(u32, n);
    defer gpa.free(argb);
    var has_alpha = false;
    for (argb, 0..) |*p, i| {
        const c = rgba[i * 4 ..][0..4];
        p.* = (@as(u32, c[3]) << 24) | (@as(u32, c[0]) << 16) | (@as(u32, c[1]) << 8) | c[2];
        has_alpha = has_alpha or c[3] != 255;
    }
    const bitstream = try vp8l_encode.encodeArgb(gpa, argb, img.width, img.height, has_alpha);
    defer gpa.free(bitstream);
    try Header.encodeLossless(w, bitstream);
}

test {
    _ = @import("bitreader.zig");
    _ = @import("huffman.zig");
    _ = @import("transform.zig");
    _ = @import("decode.zig");
    _ = @import("encode.zig");
}

test "webp encode/decode round trip - noise, palette, alpha" {
    const gpa = std.testing.allocator;
    var prng: std.Random.DefaultPrng = .init(1);
    const rand = prng.random();
    const W = 53;
    const H = 29;
    for (0..3) |case| {
        var data: [W * H * 4]u8 = undefined;
        for (0..W * H) |i| {
            const px: [4]u8 = switch (case) {
                0 => .{ rand.int(u8), rand.int(u8), rand.int(u8), rand.int(u8) },
                1 => if (rand.boolean()) .{ 10, 20, 30, 255 } else .{ 200, 100, 50, 255 },
                else => .{ @truncate(i), @truncate(i / W * 3), @truncate(i * 7), 255 },
            };
            data[i * 4 ..][0..4].* = px;
        }
        const img: Image = .{ .width = W, .height = H, .fmt = .r8g8b8a8_srgb, .pixels = try .init(.rgba, gpa, &data) };
        defer img.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try encode(&img, &aw.writer, gpa);
        const out = try Image.decode(.webp, gpa, aw.written());
        defer out.deinit(gpa);
        try Image.expectSimilar(gpa, &img, &out, .rgba, 0);
    }
}
