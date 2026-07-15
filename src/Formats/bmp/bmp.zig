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
    // Unpads each row into packed buffer - reorders rows so image row 0 = top
    // this is a memory cost - is there a more efficient way?
    const pixels_bytes = try gpa.alloc(u8, @as(usize, row_bytes) * hdr.height);
    defer gpa.free(pixels_bytes);
    for (0..hdr.height) |dst_row| {
        const src_row = if (hdr.is_top_down) dst_row else hdr.height - dst_row - 1;
        const src_start = start + src_row * stride;
        const src = data[src_start..][0..row_bytes];
        const dst = pixels_bytes[dst_row * row_bytes ..][0..row_bytes];
        @memcpy(dst, src);
    }

    var pixels: Pixels = undefined;
    var fmt: Format = undefined;
    switch (hdr.bits_per_pixel) {
        .bit_4_pallet, .bit_8_pallet, .rgb_16 => return error.UnsupportedBPP,
        .monochrome => {
            pixels = try .init(gpa, pixels_bytes, .g, .grays);
            fmt = .r8_srgb;
        },
        .rgb_24 => {
            pixels = try .init(gpa, pixels_bytes, .bgr, .rgbs);
            fmt = .r8g8b8_srgb;
        },
        .rgba => {
            pixels = try .init(gpa, pixels_bytes, .bgra, .rgbas);
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
    // row pads - each row must be padded to 4 byte stride on disk
    // row order - hdr.is_top_down false - file's first row must be image's last row
    switch (img.pixels) {
        .grays => |grays| {
            const row_bytes = img.width * 1;
            const pad = strideOf(row_bytes) - row_bytes;
            for (0..img.height) |file_row| {
                const img_row = img.height - file_row - 1;
                for (0..img.width) |col| {
                    const gray = grays[img_row * img.width + col];
                    try w.writeByte(gray.gray);
                }
                for (0..pad) |_| try w.writeByte(0);
            }
        },
        .rgbs => |rgbs| {
            const row_bytes = img.width * 3;
            const pad = strideOf(row_bytes) - row_bytes;
            for (0..img.height) |file_row| {
                const img_row = img.height - file_row - 1;
                for (0..img.width) |col| {
                    const rgb = rgbs[img_row * img.width + col];
                    try w.writeByte(rgb.blue);
                    try w.writeByte(rgb.green);
                    try w.writeByte(rgb.red);
                }
                for (0..pad) |_| try w.writeByte(0);
            }
        },
        .rgbas => |rgbas| {
            const row_bytes = img.width * 4;
            const pad = strideOf(row_bytes) - row_bytes;
            for (0..img.height) |file_row| {
                const img_row = img.height - file_row - 1;
                for (0..img.width) |col| {
                    const rgba = rgbas[img_row * img.width + col];
                    try w.writeByte(rgba.blue);
                    try w.writeByte(rgba.green);
                    try w.writeByte(rgba.red);
                    try w.writeByte(rgba.alpha);
                }
                for (0..pad) |_| try w.writeByte(0);
            }
        },
    }
    try w.flush();
}
