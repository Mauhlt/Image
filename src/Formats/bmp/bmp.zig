const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../Error.zig");

const Image = @import("../../root.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

const Header = @import("header.zig");

// pads every row to 4-byte boundary - rounds to next multiple of 4
fn strideOf(row_bytes: u32) u32 {
    return (row_bytes + 3) & ~@as(u32, 3);
}

/// SIMD
const PIXELS_PER_CHUNK = 16;
const RGB_CHUNK_BYTES = PIXELS_PER_CHUNK * 3;
const RGB_VEC = @Vector(RGB_CHUNK_BYTES, u8);
const rgb_swap_mask: @Vector(RGB_CHUNK_BYTES, i32) = blk: {
    var m: [RGB_CHUNK_BYTES]i32 = undefined;
    for (0..PIXELS_PER_CHUNK) |p| {
        m[p * 3 + 0] = p * 3 + 2;
        m[p * 3 + 1] = p * 3 + 1;
        m[p * 3 + 2] = p * 3 + 2;
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
        .bit_4_pallet, .bit_8_pallet, .rgb_16, .rgb_24 => 3,
        .rgba => 4,
    };
    const start = hdr.data_offset;
    // rows padded to 4 bytes - stride >= unpadded pixel width whenever hdr.width * bpp isnt multiple of 4
    const row_bytes = hdr.width * bpp;
    const stride = strideOf(row_bytes);
    // computes end based from stride * height
    const end = start + stride * hdr.height;
    std.debug.assert(end <= data.len);
    if (hdr.compressed_image_size > 0) {
        if (end - start != hdr.compressed_image_size) //
            return error.IncorrectCompressedImageSize;
    }
    const n_pixels = hdr.width * hdr.height;
    // // Unpads each row into packed buffer - reorders rows so image row 0 = top
    // // this is a memory cost - is there a more efficient way?
    // const pixels_bytes = try gpa.alloc(u8, @as(usize, row_bytes) * hdr.height);
    // defer gpa.free(pixels_bytes);
    // for (0..hdr.height) |dst_row| {
    //     const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
    //     const src_start = start + src_row * stride;
    //     const src = data[src_start..][0..row_bytes];
    //     const dst = pixels_bytes[dst_row * row_bytes ..][0..row_bytes];
    //     @memcpy(dst, src);
    // }

    var pixels: Pixels = undefined;
    var fmt: Format = undefined;
    switch (hdr.bits_per_pixel) {
        .bit_4_pallet, .bit_8_pallet, .rgb_16 => return error.UnsupportedBPP,
        .monochrome => {
            pixels = try .initEmpty(gpa, .grays, n_pixels);
            for (0..hdr.height) |dst_row| {
                const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
                const src = data[start + src_row * stride ..][0..row_bytes];
                const dst = pixels.grays[dst_row * hdr.width ..][0..hdr.width];
                for (src, dst) |b, *px| px.* = .{ .gray = b };
            }
            fmt = .r8_srgb;
        },
        .rgb_24 => {
            pixels = try .initEmpty(gpa, .rgbs, n_pixels);
            for (0..hdr.height) |dst_row| {
                const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
                const src = data[start + src_row * stride ..][0..row_bytes];
                const dst = pixels.rgbs[dst_row * hdr.width ..][0..hdr.width];
                for (0..hdr.width) |col| {
                    dst[col] = .{
                        .blue = src[col * 3],
                        .green = src[col * 3 + 1],
                        .red = src[col * 3 + 2],
                    };
                }
            }
            fmt = .r8g8b8_srgb;
        },
        .rgba => {
            pixels = try .initEmpty(gpa, .rgbas, n_pixels);
            for (0..hdr.height) |dst_row| {
                const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
                const src = data[start + src_row * stride ..][0..row_bytes];
                const dst = pixels.rgbas[dst_row * hdr.width ..][0..hdr.width];
                for (0..hdr.width) |col| {
                    dst[col] = .{
                        .blue = src[col * 4],
                        .green = src[col * 4 + 1],
                        .red = src[col * 4 + 2],
                        .alpha = src[col * 4 + 3],
                    };
                }
            }
            // pixels = try .init(gpa, pixels_bytes, .bgra, .rgbas);
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
            // const row_bytes = img.width * 1;
            // const pad = strideOf(row_bytes) - row_bytes;
            // for (0..img.height) |file_row| {
            //     const img_row = img.height - file_row - 1;
            //     for (0..img.width) |col| {
            //         const gray = grays[img_row * img.width + col];
            //         try w.writeByte(gray.gray);
            //     }
            //     for (0..pad) |_| try w.writeByte(0);
            // }
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
            // const row_bytes = img.width * 3;
            // const pad = strideOf(row_bytes) - row_bytes;
            // for (0..img.height) |file_row| {
            //     const img_row = img.height - file_row - 1;
            //     for (0..img.width) |col| {
            //         const rgb = rgbs[img_row * img.width + col];
            //         try w.writeByte(rgb.blue);
            //         try w.writeByte(rgb.green);
            //         try w.writeByte(rgb.red);
            //     }
            //     for (0..pad) |_| try w.writeByte(0);
            // }
        },
        .rgbas => |rgbas| {
            const row_bytes = img.width * 4;
            const pad = strideOf(row_bytes) - row_bytes;
            const zeros = [_]u8{0} ** 4;
            for (0..img.height) |file_row| {
                const img_row = img.height - file_row - 1;
                const row = rgbas[img_row * img.width ..][0..img.width];
                try writeRgbaRowSwapped(w, std.mem.sliceAsBytes(row), img.width);
                try w.writeALl(zeros[0..pad]);
            }
            // const row_bytes = img.width * 4;
            // const pad = strideOf(row_bytes) - row_bytes;
            // for (0..img.height) |file_row| {
            //     const img_row = img.height - file_row - 1;
            //     for (0..img.width) |col| {
            //         const rgba = rgbas[img_row * img.width + col];
            //         try w.writeByte(rgba.blue);
            //         try w.writeByte(rgba.green);
            //         try w.writeByte(rgba.red);
            //         try w.writeByte(rgba.alpha);
            //     }
            //     for (0..pad) |_| try w.writeByte(0);
            // }
        },
    }
    try w.flush();
}
