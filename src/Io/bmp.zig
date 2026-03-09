const std = @import("std");
const Image = @import("Image.zig").Image;
const isSigSame = @import("Misc.zig").isSigSame;
// https://www.ece.ualberta.ca/~elliott/ee552/studentAppNotes/2003_w/misc/bmp_file_format/bmp_file_format.htm
// scanlines = bottom to top
// each scan line is 0 padded to nearest 4-byte boundary
// rgb values stored bockwards - bgr
// 4 bit + 8 bit bmps can be compressed

/// To fulfull interface: needs read, write, toImage, copyToImage
hdr: Header,
body: Body,

pub fn read(self: *@This(), r: *std.Io.Reader, allo: std.mem.Allocator) !@This() {
    self.hdr = try .read(r, allo);
    self.body = try .read(r, allo, &self.hdr);
}

/// Converts data written from this file type as this file type
pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const BitsPerPixel = enum(u16) {
    monochrome_palette = 1,
    pallet_4_bit = 4,
    pallet_8_bit = 8,
    rgb_16 = 16,
    rgb_24 = 24,
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

    pub fn read(
        r: *std.Io.Reader,
        allo: *const std.mem.Allocator,
    ) !@This() {
        _ = allo;
        // signature
        const sig = try r.take(2);
        try isSigSame(sig, SIG);

        // header
        const file_size = try r.takeInt(u32, .little);
        var curr_file_size = file_size - @as(@TypeOf(file_size), @truncate(sig.len));
        curr_file_size = try checkSize(curr_file_size, file_size);

        const reserved = try r.takeInt(u32, .little);
        curr_file_size = try checkSize(curr_file_size, reserved);

        const data_offset = try r.takeInt(u32, .little);
        curr_file_size = try checkSize(curr_file_size, data_offset);
        if ((file_size - curr_file_size) != 14) {
            std.debug.print("{} - {}: {}\n", .{ file_size, curr_file_size, file_size - curr_file_size });
            return error.IncorrectHeaderSize;
        }

        // info header
        const info_hdr_size = try r.takeInt(u32, .little);
        var curr_info_hdr_size = info_hdr_size;
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, info_hdr_size);

        const width = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, width);
        std.debug.print("Width: {}\n", .{width});

        const height = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, height);
        std.debug.print("Height: {}\n", .{height});

        const planes = try r.takeInt(u16, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, planes);

        const bits_per_pixel_num = try r.takeInt(u16, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, bits_per_pixel_num);
        const bits_per_pixel = std.enums.fromInt(BitsPerPixel, bits_per_pixel_num) orelse
            return error.InvalidBitsPerPixelEnumValue;

        const compress_num = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, compress_num);
        const compression = std.enums.fromInt(Compression, compress_num) orelse
            return error.InvalidEnumValue;
        if (compress_num != .rgb) return error.UnsupportedCompressionNumber;

        const compressed_image_size = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, compressed_image_size);

        const x_pixels_per_mm = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, x_pixels_per_mm);

        const y_pixels_per_mm = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, y_pixels_per_mm);

        const colors_used = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, colors_used);

        const important_colors = try r.takeInt(u32, .little);
        curr_info_hdr_size = try checkSize(curr_info_hdr_size, important_colors);

        // uncompressed if pixel data begins after color table
        if (data_offset > 54) {
            return error.UnsupportedDataOffset;
            // color table
            // const total_possible_number_of_colors: u64 = switch (bits_per_pixel) {
            //     .monochrome_palette => @as(u32, 1) << 0,
            //     .pallet_4_bit => @as(u32, 1) << 4,
            //     .pallet_8_bit => @as(u32, 1) << 8,
            //     .rgb_16 => @as(u32, 1) << 16,
            //     .rgb_24 => @as(u32, 1) << 24,
            // };
            // file_size = try checkFileSize(file_size, data_offset);

            // var color_table = try allo.alloc([4]u8, total_possible_number_of_colors);
            // errdefer allo.free(color_table);
            // file_size = try checkFileSize(file_size, data_offset);
            // for (0..colors_used) |i| {
            //     color_table[i] = (try r.takeArray(4)).*;
            // }
        }

        if (@import("builtin").mode == .Debug and
            (info_hdr_size - curr_info_hdr_size) != 40)
        {
            std.debug.print(
                "{} - {} = {}\n",
                .{ info_hdr_size, curr_info_hdr_size, info_hdr_size - curr_info_hdr_size },
            );
            return error.FileSizeMismatch;
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
        allo: *const std.mem.Allocator,
        hdr: *const Header,
    ) !@This() {
        const len = hdr.width * hdr.height / 4;
        return .{
            .data = @ptrCast(try r.readAlloc(allo.*, len)),
        };
    }

    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        try w.writeAll(self.data);
    }

    pub fn free(
        self: *const Body,
        allo: *const std.mem.Allocator,
    ) void {
        allo.free(self.data);
    }
};

/// Used for file size + info hdr size
fn checkSize(size: u32, field: anytype) !u32 {
    const bits: u32 = @sizeOf(@TypeOf(field));
    if (size < bits) {
        std.debug.print("Size: {}, Bits: {}\n", .{ size, bits });
        return error.IncorrectSize;
    }
    return size - bits;
}
