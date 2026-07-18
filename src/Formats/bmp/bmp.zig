const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../Error.zig");

const Image = @import("../../root.zig");
const GRAY = @import("../../Colors/pixel_format.zig").GRAY;
const BGR = @import("../../Colors/pixel_format.zig").BGR;
const BGRA = @import("../../Colors/pixel_format.zig").BGRA;
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

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

fn swapRgbRow(dst: []u8, src: []const u8, width: usize) void {
    var i: usize = 0;
    while (i + PIXELS_PER_CHUNK <= width) : (i += PIXELS_PER_CHUNK) {
        const s: RGB_VEC = src[i * 3 ..][0..RGB_CHUNK_BYTES].*;
        dst[i * 3 ..][0..RGB_CHUNK_BYTES].* = @shuffle(u8, s, undefined, rgb_swap_mask);
    }
    while (i < width) : (i += 1) {
        dst[i * 3 + 0] = src[i * 3 + 2];
        dst[i * 3 + 1] = src[i * 3 + 1];
        dst[i * 3 + 2] = src[i * 3 + 0];
    }
}

fn swapRgbaRow(dst: []u8, src: []const u8, width: usize) void {
    var i: usize = 0;
    while (i + PIXELS_PER_CHUNK <= width) : (i += PIXELS_PER_CHUNK) {
        const s: RGBA_VEC = src[i * 4 ..][0..RGBA_CHUNK_BYTES].*;
        dst[i * 4 ..][0..RGBA_CHUNK_BYTES].* = @shuffle(u8, s, undefined, rgba_swap_mask);
    }
    while (i < width) : (i += 1) {
        dst[i * 4 + 0] = src[i * 4 + 2];
        dst[i * 4 + 1] = src[i * 4 + 1];
        dst[i * 4 + 2] = src[i * 4 + 0];
        dst[i * 4 + 3] = src[i * 4 + 3];
    }
}

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

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    const hdr: Header = try .decode(data);
    const bpp: @TypeOf(hdr.width) = switch (hdr.bits_per_pixel) {
        .monochrome => 1,
        .rgb_24 => 3,
        .rgba => 4,
        else => return error.UnsupportedBPP,
    };
    const start = hdr.data_offset;
    const row_bytes = hdr.width * bpp;
    const stride = strideOf(row_bytes);
    const end = start + stride * hdr.height; // end - start can equal hdr.compressed_image_size
    if (end > data.len) return error.InvalidDataOffset;
    if (hdr.compressed_image_size > 0) {
        if (end - start != hdr.compressed_image_size) //
            return error.InvalidDataOffset;
    }
    const n_pixels = hdr.width * hdr.height;

    var pixels: Pixels = undefined;
    var fmt: Format = undefined;
    switch (hdr.bits_per_pixel) {
        .bit_4_pallet, .bit_8_pallet, .rgb_16 => unreachable,
        .monochrome => {
            const slice = try gpa.alloc(GRAY, n_pixels);
            pixels = .{ .grays = try gpa.alloc(GRAY, n_pixels) };
            for (0..hdr.height) |dst_row| {
                const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
                const src = data[start + src_row * stride ..][0..row_bytes];
                const dst = slice[dst_row * hdr.width ..][0..hdr.width];
                @memcpy(dst, @as([]const GRAY, @ptrCast(src)));
            }
            pixels = .{ .grays = slice };
            fmt = .r8_srgb;
        },
        .rgb_24 => {
            const slice = gpa.alloc(BGR, n_pixels);
            for (0..hdr.height) |dst_row| {
                const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
                const src = data[start + src_row * stride ..][0..row_bytes];
                const dst = slice[dst_row * hdr.width ..][0..hdr.width];
                @memcpy(dst, @as([]const BGR, @ptrCast(src)));
            }
            pixels = .{ .bgrs = slice };
            fmt = .r8g8b8_srgb;
        },
        .rgba => {
            const slice = try gpa.alloc(BGRA, n_pixels);
            for (0..hdr.height) |dst_row| {
                const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
                const src = data[start + src_row * stride ..][0..row_bytes];
                const dst = slice[dst_row * hdr.width ..][0..hdr.width];
                @memcpy(dst, @as([]const BGRA, @ptrCast(src)));
            }
            pixels = .{ .bgras = slice };
            fmt = .r8g8b8a8_srgb;
        },
    }
    return .{
        .width = hdr.width,
        .height = hdr.height,
        .fmt = fmt,
        .pixels = pixels,
    };
}

pub fn encode(img: *const Image, w: *std.Io.Writer, maybe_hdr: ?Header) !void {
    const hdr: Header = if (maybe_hdr) |hdr| hdr else try .fromImage(img);
    try hdr.encode(w);
    switch (img.pixels) {
        .grays => |grays| {
            const row_bytes = img.width;
            const pad = strideOf(row_bytes) - row_bytes; // pad to 4 bytes
            const zeros = [_]u8{0} ** 4;
            for (0..img.height) |file_row| {
                const img_row = img.height - file_row - 1;
                const row = grays[img_row * img.width ..][0..img.width];
                try w.writeAll(std.mem.sliceAsBytes(row));
                try w.writeAll(zeros[0..pad]);
            }
        },
        .rgbs => |rgbs| {
            const row_bytes = img.width * 3;
            const pad = strideOf(row_bytes) - row_bytes;
            const zeros = [_]u8{0} ** 4;
            for (0..img.height) |file_row| {
                const img_row = img.height - file_row - 1;
                const row = rgbs[img_row * img.width ..][0..img.width];
                try writeRgbRowSwapped(w, std.mem.sliceAsBytes(row), img.width);
                try w.writeAll(zeros[0..pad]);
            }
        },
        .rgbas => |rgbas| {
            const row_bytes = img.width * 4;
            const pad = strideOf(row_bytes) - row_bytes;
            const zeros = [_]u8{0} ** 4;
            for (0..img.height) |file_row| {
                const img_row = img.height - file_row - 1;
                const row = rgbas[img_row * img.width ..][0..img.width];
                try writeRgbaRowSwapped(w, std.mem.sliceAsBytes(row), img.width);
                try w.writeAll(zeros[0..pad]);
            }
        },
    }
    try w.flush();
}
