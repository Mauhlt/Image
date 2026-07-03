const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../Error.zig");

const Image = @import("../../root.zig");

const GRAY = @import("../../Colors/gray.zig");
const GRAYS = @import("../../Colors/grays.zig");
const RGB = @import("../../Colors/rgb.zig");
const RGBS = @import("../../Colors/rgbs.zig");
const RGBA = @import("../../Colors/rgba.zig");
const RGBAS = @import("../../Colors/rgbas.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

const isSigSame = @import("../Misc.zig").isSigSame;

const Header = @import("header.zig");

// Basics
pub const BitsPerPixel = enum(u8) {
    monochrome = 1,
    bit_4_pallet = 4,
    bit_8_pallet = 8,
    rgb_16 = 16,
    rgb_24 = 24,
    rgba = 32,
};

pub const Compression = enum(u32) {
    none = 0,
    rle8 = 1,
    rle4 = 2,
};

pub const SIG: []const u8 = "BM";

// https://www.ece.ualberta.ca/~elliott/ee552/studentAppNotes/2003_w/misc/bmp_file_format/bmp_file_format.htm
pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    const hdr: Header = try .decode(data);
    // defer hdr.deinit(gpa);
    // std.debug.print("{f}", .{hdr});
    // std.debug.assert(hdr.depth == 1);
    const bpp: @TypeOf(hdr.width) = switch (hdr.bits_per_pixel) {
        .monochrome => 1,
        .bit_4_pallet, .bit_8_pallet, .rgb_16, .rgb_24 => 3,
        .rgba => 4,
    };
    const exp_n_pixels = hdr.width * hdr.height;
    const start = hdr.data_offset;
    const end = start + hdr.compressed_image_size;
    // std.debug.print(
    //     "Start: {}\nEnd: {}\nData Len: {}\n",
    //     .{ start, end, data.len },
    // );
    std.debug.assert(end <= data.len and start <= data.len);
    const pixels_slice = data[start..end];
    const n_pixels = pixels_slice.len / bpp;
    std.debug.assert(n_pixels == exp_n_pixels);
    var pixels: Pixels = undefined;
    var fmt: Format = undefined;
    switch (hdr.bits_per_pixel) {
        .bit_4_pallet, .bit_8_pallet, .rgb_16 => unreachable,
        .monochrome => {
            pixels = try .init(gpa, pixels_slice, .g, .gray);
            fmt = .r8_srgb;
        },
        .rgb_24 => {
            pixels = try .init(gpa, pixels_slice, .bgr, .rgb);
            fmt = .r8g8b8_srgb;
        },
        .rgba => {
            pixels = try .init(gpa, pixels_slice, .bgra, .rgba);
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
        .gray => |grays| {
            for (0..grays.len) |i| {
                const gray = try grays.get(i);
                try w.writeByte(gray.g);
            }
        },
        .rgb => |rgbs| {
            for (0..rgbs.len) |i| {
                const rgb = try rgbs.get(i);
                try w.writeByte(rgb.b);
                try w.writeByte(rgb.g);
                try w.writeByte(rgb.r);
            }
        },
        .rgba => |rgbas| {
            for (0..rgbas.len) |i| {
                const rgba = try rgbas.get(i);
                try w.writeByte(rgba.b);
                try w.writeByte(rgba.g);
                try w.writeByte(rgba.r);
                try w.writeByte(rgba.a);
            }
        },
    }
    try w.flush();
}
