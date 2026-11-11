//! BMP / DIB: decodes 1/4/8-bit palette, 24-bit and 32-bit (incl. BI_BITFIELDS) images,
//! bottom-up or top-down. Encodes g (8-bit gray palette), 24-bit and 32-bit.
const std = @import("std");
const Error = @import("../error.zig").Error;

const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;

const Header = @import("header.zig");
const strideOf = @import("misc.zig").strideOf;

/// SIMD
const PIXELS_PER_CHUNK = 16;
const RGB_CHUNK_BYTES = PIXELS_PER_CHUNK * 3;
const RGB_VEC = @Vector(RGB_CHUNK_BYTES, u8);
const rgb_swap_mask: @Vector(RGB_CHUNK_BYTES, i32) = blk: {
    var m: [RGB_CHUNK_BYTES]i32 = undefined;
    for (0..PIXELS_PER_CHUNK) |p| {
        m[p * 3 + 0] = p * 3 + 2;
        m[p * 3 + 1] = p * 3 + 1;
        m[p * 3 + 2] = p * 3 + 0;
    }
    break :blk m;
};
const RGBA_CHUNK_BYTES = PIXELS_PER_CHUNK * 4;
const RGBA_VEC = @Vector(RGBA_CHUNK_BYTES, u8);
const rgba_swap_mask: @Vector(RGBA_CHUNK_BYTES, i32) = blk: {
    var m: [RGBA_CHUNK_BYTES]i32 = undefined;
    for (0..PIXELS_PER_CHUNK) |p| {
        m[p * 4 + 0] = p * 4 + 2;
        m[p * 4 + 1] = p * 4 + 1;
        m[p * 4 + 2] = p * 4 + 0;
        m[p * 4 + 3] = p * 4 + 3;
    }
    break :blk m;
};

fn writeRgbRowSwapped(w: *std.Io.Writer, src: []const u8, width: usize) !void {
    var i: usize = 0;
    while (i + PIXELS_PER_CHUNK <= width) : (i += PIXELS_PER_CHUNK) {
        const s: RGB_VEC = src[i * 3 ..][0..RGB_CHUNK_BYTES].*;
        const d: RGB_VEC = @shuffle(u8, s, undefined, rgb_swap_mask);
        try w.writeAll(&@as([RGB_CHUNK_BYTES]u8, d));
    }
    while (i < width) : (i += 1) {
        try w.writeByte(src[i * 3 + 2]);
        try w.writeByte(src[i * 3 + 1]);
        try w.writeByte(src[i * 3 + 0]);
    }
}

fn writeRgbaRowSwapped(w: *std.Io.Writer, src: []const u8, width: usize) !void {
    var i: usize = 0;
    while (i + PIXELS_PER_CHUNK <= width) : (i += PIXELS_PER_CHUNK) {
        const s: RGBA_VEC = src[i * 4 ..][0..RGBA_CHUNK_BYTES].*;
        const d: RGBA_VEC = @shuffle(u8, s, undefined, rgba_swap_mask);
        try w.writeAll(&@as([RGBA_CHUNK_BYTES]u8, d));
    }
    while (i < width) : (i += 1) {
        try w.writeByte(src[i * 4 + 2]);
        try w.writeByte(src[i * 4 + 1]);
        try w.writeByte(src[i * 4 + 0]);
        try w.writeByte(src[i * 4 + 3]);
    }
}

pub fn info(data: []const u8) !Info {
    const hdr: Header = try .decode(data);
    const tag: PixelTag = switch (hdr.bits_per_pixel) {
        .rgb_24 => .bgr,
        .rgba_32 => .bgra,
        else => if (hdr.isGrayPalette()) .g else .bgr,
    };
    return .{ .width = hdr.width, .height = hdr.height, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    _ = scratch;
    const hdr: Header = try .decode(data);
    const width: usize = hdr.width;
    const out_bpp = inf.tag.bytesPerPixel();
    const row_bytes = hdr.rowBytes();
    const stride = hdr.stride();
    const depth: usize = @intFromEnum(hdr.bits_per_pixel);
    for (0..hdr.height) |y| {
        const src_row = if (hdr.is_top_down) y else hdr.height - 1 - y;
        const src = data[hdr.data_offset + src_row * stride ..][0..row_bytes];
        const dst = out[y * width * out_bpp ..][0 .. width * out_bpp];
        switch (hdr.bits_per_pixel) {
            .rgb_24, .rgba_32 => @memcpy(dst, src),
            .bit_1_palette, .bit_4_palette, .bit_8_palette => {
                const n_pal = hdr.paletteLen();
                for (0..width) |x| {
                    const idx: usize = switch (depth) {
                        8 => src[x],
                        4 => (src[x / 2] >> @intCast(4 - 4 * (x % 2))) & 0xF,
                        1 => (src[x / 8] >> @intCast(7 - (x % 8))) & 1,
                        else => unreachable,
                    };
                    if (idx >= n_pal) return Error.OutOfBounds;
                    const e = hdr.palette[idx * 4 ..][0..3];
                    if (inf.tag == .g) dst[x] = e[0] else dst[x * 3 ..][0..3].* = e.*;
                }
            },
            .rgb_16 => return Error.UnsupportedBitsPerPixel,
        }
    }
}

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    // BMP stores gray (palette), BGR or BGRA; convert anything else
    const tag: PixelTag = switch (img.pixels) {
        .g, .ga => .g,
        .rgb, .bgr, .ycbcr => .bgr,
        .rgba, .bgra, .ycbcra => .bgra,
    };
    const active = std.meta.activeTag(img.pixels);
    const swap = (active == .rgb and tag == .bgr) or (active == .rgba and tag == .bgra);
    const converted = if (active == tag or swap) null else try img.pixels.convertV(tag, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const src = (converted orelse img.pixels).asBytes();

    const hdr: Header = try .init(img.width, img.height, switch (tag) {
        .g => .bit_8_palette,
        .bgr => .rgb_24,
        else => .rgba_32,
    });
    try hdr.encode(w);

    const width: usize = img.width;
    const bpp = tag.bytesPerPixel();
    const row_bytes = width * bpp;
    const pad = strideOf(row_bytes) - row_bytes;
    const zeros: [4]u8 = @splat(0);
    for (0..img.height) |file_row| {
        const img_row = img.height - 1 - file_row; // bottom-up
        const row = src[img_row * row_bytes ..][0..row_bytes];
        if (!swap) {
            try w.writeAll(row);
        } else if (bpp == 3) {
            try writeRgbRowSwapped(w, row, width);
        } else {
            try writeRgbaRowSwapped(w, row, width);
        }
        try w.writeAll(zeros[0..pad]);
    }
}
