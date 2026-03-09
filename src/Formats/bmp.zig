const std = @import("std");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");
const Image = @import("../root.zig");
const BitType = @import("../root.zig").BitType;
const isSigSame = @import("Misc.zig").isSigSame;

// https://www.ece.ualberta.ca/~elliott/ee552/studentAppNotes/2003_w/misc/bmp_file_format/bmp_file_format.htm
// scanlines = bottom to top
// each scan line is 0 padded to nearest 4-byte boundary
// rgb values stored bockwards - bgr
// 4 bit + 8 bit bmps can be compressed

pub fn read(r: *std.Io.Reader, gpa: std.mem.Allocator) !Image {
    const hdr: Header = try .read(r, gpa);
    const bytes = r.readAlloc(gpa, hdr.compressed_image_size) catch |err| switch (err) {
        error.OutOfMemory => {},
        else => std.debug.print("Here", .{}),
    };
    // create img
    var img: Image = .{
        .width = hdr.width,
        .height = hdr.height,
        .pixels = switch (hdr.bits_per_pixel) {
            .rgba => .{ .rgba = @as([]RGBA, @ptrCast(@alignCast(bytes))).ptr },
            else => .{ .rgb = @as([]RGB, @ptrCast(@alignCast(bytes))).ptr },
        },
    };
    // flip pixels: bgr to rgb order
    switch (img.pixels) {
        inline else => |data| {
            const len = img.width * img.height;
            for (data[0..len]) |*datum| datum.* = datum.flip();
        }
    }
    return img;
}

const BitsPerPixel = enum(u16) {
    monochrome_palette = 1,
    pallet_4_bit = 4,
    pallet_8_bit = 8,
    rgb_16 = 16,
    rgb_24 = 24,
    rgba = 32,
};

const Compression = enum(u32) {
    rgb, // no compression
    rle8 = 1,
    rle4 = 2,
};

const Header = struct {
    pub const SIG: []const u8 = "BM";
    // header
    file_size: u32,
    reserved: u32,
    data_offset: u32,
    // info header
    info_hdr_size: u32,
    width: u32,
    height: u32,
    planes: u16,
    bits_per_pixel: BitsPerPixel,
    compression: Compression,
    compressed_image_size: u32, // 0 = no compression
    x_pixels_per_mm: u32,
    y_pixels_per_mm: u32,
    colors_used: u32, // for 8 bit / pixel bitmap = 100h or 256
    important_colors: u32,
    // color table
    // number_of_colors: u64,
    // color_table: [][4]u8, // rgb reserved

    /// reading from a file
    pub fn read(
        r: *std.Io.Reader,
        gpa: std.mem.Allocator,
    ) !@This() {
        _ = gpa;
        // signature
        const sig = try r.take(2);
        try isSigSame(sig, SIG);

        // header
        const file_size = try r.takeInt(u32, .little);
        // const curr_file_size = file_size - @as(@TypeOf(file_size), @truncate(sig.len));
        const reserved = try r.takeInt(u32, .little);
        const data_offset = try r.takeInt(u32, .little);

        // info header
        const info_hdr_size = try r.takeInt(u32, .little); // changes based on dib or bmp
        const width = try r.takeInt(u32, .little);
        const height = try r.takeInt(u32, .little);
        const planes = try r.takeInt(u16, .little);
        const bits_per_pixel_num = try r.takeInt(u16, .little);
        const bits_per_pixel = std.enums.fromInt(BitsPerPixel, bits_per_pixel_num) orelse
            return error.InvalidBitsPerPixelEnumValue;
        const compress_num = try r.takeInt(u32, .little);
        const compression = std.enums.fromInt(Compression, compress_num) orelse
            return error.InvalidEnumValue;
        switch (compression) {
            .rgb => {},
            else => return error.UnsupportedCompressionNumber,
        }
        const compressed_image_size = try r.takeInt(u32, .little); // amount of bytes to read
        const x_pixels_per_mm = try r.takeInt(u32, .little);
        const y_pixels_per_mm = try r.takeInt(u32, .little);
        const colors_used = try r.takeInt(u32, .little);
        const important_colors = try r.takeInt(u32, .little);

        if (data_offset > 54) {
            return error.UnsupportedDataOffset;
        }

        return .{
            // hdr
            .file_size = file_size,
            .reserved = reserved,
            .data_offset = data_offset,
            // info hdr
            .info_hdr_size = info_hdr_size,
            .width = width,
            .height = height,
            .planes = planes,
            .bits_per_pixel = bits_per_pixel,
            .compression = compression,
            .compressed_image_size = compressed_image_size,
            .x_pixels_per_mm = x_pixels_per_mm,
            .y_pixels_per_mm = y_pixels_per_mm,
            .colors_used = colors_used,
            .important_colors = important_colors,
            // color table
            // .number_of_colors = number_of_colors,
            // .color_table = color_table,
        };
    }

    /// writing to a file
    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        // hdr
        try w.writeAll(SIG);
        try w.writeInt(u32, self.file_size, .little);
        try w.writeInt(u32, self.reserved, .little);
        try w.writeInt(u32, self.dadat_offset, .little);
        // info hdr
        try w.writeInt(u32, self.info_hdr_size, .little);
        try w.writeInt(u32, self.width, .little);
        try w.writeInt(u32, self.height, .little);
        try w.writeInt(u16, self.planes, .little);
        try w.writeInt(u16, @intFromEnum(self.bits_per_pixel), .little);
        try w.writeInt(u32, @intFromEnum(self.compression), .little);
        try w.writeInt(u32, self.compressed_image_size, .little);
        try w.writeInt(u32, self.x_pixels_per_mm, .little);
        try w.writeInt(u32, self.y_pixels_per_mm, .little);
        try w.writeInt(u32, self.colors_used, .little);
        try w.writeInt(u32, self.important_colors, .little);
        // color table - not implemented
    }
};

const Body = union(enum) {
    rgb: [*]RGB,
    rgba: [*]RGBA,

    pub fn read(
        r: *std.Io.Reader,
        gpa: std.mem.Allocator,
        hdr: *const Header,
    ) !@This() {
        std.debug.assert(hdr.width > 0 and hdr.height > 0);
        const data = try r.readAlloc(gpa, hdr.compressed_image_size);
        switch (hdr.compression) {
            .rgb => {},
            else => return error.UnsupportedCompression,
        }
        return switch (hdr.bits_per_pixel) {
            .rgba => .{ .rgba = @ptrCast(@alignCast(data)) },
            else => .{ .rgb = @ptrCast(@alignCast(data)) },
        };
    }

    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        try w.writeAll(self.data);
    }

    pub fn free(
        self: Body,
        gpa: std.mem.Allocator,
    ) void {
        gpa.free(self.data);
    }
};
