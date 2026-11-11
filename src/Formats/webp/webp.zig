//! WebP: lossless (VP8L) decode + encode, lossy (VP8, with optional ALPH
//! alpha) decode, in simple and extended (VP8X) containers. Animation is rejected.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const Header = @import("header.zig");
const vp8l_decode = @import("decode.zig");
const vp8l_encode = @import("encode.zig");
const vp8 = @import("vp8.zig");
const alpha = @import("alpha.zig");
const yuv = @import("yuv.zig");

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data);
    const tag: PixelTag = if (hdr.alpha) .rgba else .rgb;
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const hdr: Header = try .decode(data);
    if (hdr.width != inf.width or hdr.height != inf.height) return Error.InvalidDimensions;
    if (hdr.codec == .lossy) return decodeLossy(scratch, hdr, inf, out);
    const n = @as(usize, hdr.width) * hdr.height;
    const argb = try scratch.alloc(u32, n);
    defer scratch.free(argb);
    try vp8l_decode.decodeArgb(scratch, hdr.bitstream, hdr.width, hdr.height, argb);
    switch (inf.tag) {
        .rgba => argbToBytes(4, argb, out),
        .rgb => argbToBytes(3, argb, out),
        else => return Error.UnsupportedPixels,
    }
}

/// ARGB pixels -> r, g, b(, a) bytes, 16 pixels per shuffle.
fn argbToBytes(comptime channels: usize, argb: []const u32, out: []u8) void {
    var i: usize = 0;
    while (i + 16 <= argb.len) : (i += 16) argbToBytesN(16, channels, argb, out, i);
    while (i < argb.len) : (i += 1) argbToBytesN(1, channels, argb, out, i);
}

fn argbToBytesN(comptime n: usize, comptime channels: usize, argb: []const u32, out: []u8, i: usize) void {
    var px: @Vector(n, u32) = argb[i..][0..n].*;
    if (@import("builtin").cpu.arch.endian() == .big) px = @byteSwap(px);
    const mask = comptime blk: {
        const byte_of = [4]i32{ 2, 1, 0, 3 }; // r, g, b, a in a little-endian ARGB word
        var m: [n * channels]i32 = undefined;
        for (0..n) |p| for (0..channels) |c| {
            m[p * channels + c] = 4 * p + byte_of[c];
        };
        break :blk m;
    };
    const bytes: @Vector(4 * n, u8) = @bitCast(px);
    out[i * channels ..][0 .. n * channels].* = @shuffle(u8, bytes, undefined, mask);
}

fn decodeLossy(scratch: std.mem.Allocator, hdr: Header, inf: Info, out: []u8) !void {
    const channels: usize = switch (inf.tag) {
        .rgb => 3,
        .rgba => 4,
        else => return Error.UnsupportedPixels,
    };
    const planes = try vp8.decode(scratch, hdr.bitstream);
    defer planes.deinit(scratch);
    if (planes.width != hdr.width or planes.height != hdr.height) return Error.InvalidDimensions;
    var a: ?[]u8 = null;
    defer if (a) |buf| scratch.free(buf);
    if (channels == 4) {
        if (hdr.alpha_chunk) |chunk| {
            a = try scratch.alloc(u8, @as(usize, hdr.width) * hdr.height);
            try alpha.decode(scratch, chunk, hdr.width, hdr.height, a.?);
        }
    }
    yuv.toRgb(&planes, a, channels, out);
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
    _ = @import("vp8.zig");
    _ = @import("alpha.zig");
    _ = @import("yuv.zig");
}

test "ARGB to rgb / rgba bytes" {
    var argb: [21]u32 = undefined; // one 16-pixel vector and a tail
    for (&argb, 0..) |*p, i| p.* = @as(u32, @intCast(i)) *% 0x9E3779B9;
    var rgba: [21 * 4]u8 = undefined;
    var rgb: [21 * 3]u8 = undefined;
    argbToBytes(4, &argb, &rgba);
    argbToBytes(3, &argb, &rgb);
    for (argb, 0..) |p, i| {
        const want = [4]u8{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p), @truncate(p >> 24) };
        try std.testing.expectEqualSlices(u8, &want, rgba[4 * i ..][0..4]);
        try std.testing.expectEqualSlices(u8, want[0..3], rgb[3 * i ..][0..3]);
    }
}

/// Splits a golden image from golang.org/x/image's testdata: a gray image
/// holding Y on top, then U | V side by side, then (optionally) alpha.
/// Those planes were produced by libwebp, so they must match exactly.
fn expectPlanesMatchGolden(gpa: std.mem.Allocator, webp_path: []const u8, golden_path: []const u8) !void {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const data = try cwd.readFileAlloc(io, webp_path, gpa, .unlimited);
    defer gpa.free(data);
    const golden = try Image.read(.{ .io = io, .gpa = gpa, .filepath = golden_path });
    defer golden.deinit(gpa);
    const g = golden.pixels.asBytes(); // gray: one byte per pixel

    const hdr: Header = try .decode(data);
    const planes = try vp8.decode(gpa, hdr.bitstream);
    defer planes.deinit(gpa);
    const w: usize = planes.width;
    const h: usize = planes.height;
    const w2 = (w + 1) / 2;
    const h2 = (h + 1) / 2;
    const gw: usize = golden.width;
    try std.testing.expectEqual(2 * w2, gw);

    var mismatches: usize = 0;
    const Plane = struct { name: []const u8, pix: []const u8, stride: usize, x0: usize, y0: usize, w: usize, h: usize };
    var list: [4]Plane = .{
        .{ .name = "Y", .pix = planes.y, .stride = planes.y_stride, .x0 = 0, .y0 = 0, .w = w, .h = h },
        .{ .name = "U", .pix = planes.u, .stride = planes.uv_stride, .x0 = 0, .y0 = h, .w = w2, .h = h2 },
        .{ .name = "V", .pix = planes.v, .stride = planes.uv_stride, .x0 = w2, .y0 = h, .w = w2, .h = h2 },
        undefined,
    };
    var n_planes: usize = 3;
    var a_buf: ?[]u8 = null;
    defer if (a_buf) |b| gpa.free(b);
    if (golden.height == 2 * h + h2) {
        a_buf = try gpa.alloc(u8, w * h);
        // like decodeInto, the lossless decoder's temporaries go in an arena
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try alpha.decode(arena.allocator(), hdr.alpha_chunk orelse return error.MissingAlpha, w, h, a_buf.?);
        list[3] = .{ .name = "A", .pix = a_buf.?, .stride = w, .x0 = 0, .y0 = h + h2, .w = w, .h = h };
        n_planes = 4;
    }
    for (list[0..n_planes]) |p| for (0..p.h) |j| {
        const got = p.pix[j * p.stride ..][0..p.w];
        const want = g[(p.y0 + j) * gw + p.x0 ..][0..p.w];
        if (!std.mem.eql(u8, got, want)) {
            mismatches += 1;
            if (mismatches <= 5) std.debug.print("{s}: {s} plane row {d} differs\n", .{ webp_path, p.name, j });
        }
    };
    try std.testing.expectEqual(@as(usize, 0), mismatches);
}

test "lossy webp RGB(A) matches Windows' WebP decoder" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = "src/Data/Read/vp8/";
    inline for (.{
        .{ "yellow_rose.lossy.webp", PixelTag.rgb },
        .{ "yellow_rose.lossy-with-alpha.webp", PixelTag.rgba },
        .{ "video-001.lossy.webp", PixelTag.rgb },
    }) |case| {
        const ours = try Image.read(.{ .io = io, .gpa = gpa, .filepath = dir ++ case[0] });
        defer ours.deinit(gpa);
        const wic = try Image.read(.{ .io = io, .gpa = gpa, .filepath = dir ++ case[0] ++ ".wic.png" });
        defer wic.deinit(gpa);
        try Image.expectSimilar(gpa, &wic, &ours, case[1], 0);
    }
}

test "lossy webp planes match libwebp exactly" {
    const dir = "src/Data/Read/vp8/";
    inline for (.{
        "blue-purple-pink.lossy.webp",
        "blue-purple-pink-large.no-filter.lossy.webp",
        "blue-purple-pink-large.simple-filter.lossy.webp",
        "blue-purple-pink-large.normal-filter.lossy.webp",
        "video-001.lossy.webp",
        "yellow_rose.lossy.webp",
    }) |name| try expectPlanesMatchGolden(std.testing.allocator, dir ++ name, dir ++ name ++ ".ycbcr.png");
    try expectPlanesMatchGolden(std.testing.allocator, dir ++ "yellow_rose.lossy-with-alpha.webp", dir ++ "yellow_rose.lossy-with-alpha.webp.nycbcra.png");
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
