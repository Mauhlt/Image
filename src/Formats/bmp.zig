const std = @import("std");
const Error = @import("Error.zig");
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
    defer hdr.deinit(gpa);

    const total_bytes: u32 = hdr.width * hdr.height * hdr.n_channels;

    // read all the data
    var data = try r.readAlloc(gpa, total_bytes);
    defer gpa.free(data);

    const pixels = try gpa.alloc(u8, total_bytes);
    errdefer gpa.free(pixels);

    var row: u32 = 0;
    while (row < hdr.height) : (row +%= 1) {
        // bottom-up = default
        // top-down if height is negative
        const src_row = if (hdr.is_top_down) row else hdr.height - row - 1;
        const src_offset: u32 = hdr.pixel_data_offset + src_row * hdr.n_pixels_per_row;
        const dst_offset: u32 = row * hdr.width * hdr.n_channels;

        var col: u32 = 0;
        while (col < hdr.width) : (col +%= 1) {
            switch (hdr.bits_per_pixel) {
                8 => {
                    const idx = data[src_offset + col];
                    const entry = hdr.color_table[idx];
                    const dst = dst_offset + col * 3;
                    pixels[dst] = entry[0];
                    pixels[dst + 1] = entry[1];
                    pixels[dst + 2] = entry[2];
                },
                24 => {
                    const src = src_offset + col * hdr.n_channels;
                    const dst = dst_offset + col * hdr.n_channels;
                    pixels[dst] = data[src + 2];
                    pixels[dst + 1] = data[src + 1];
                    pixels[dst + 2] = data[src];
                },
                32 => {
                    const src = src_offset + col * hdr.n_channels;
                    const dst = dst_offset + col * hdr.n_channels;
                    pixels[dst] = data[src + 2]; // r
                    pixels[dst + 1] = data[src + 1]; // g
                    pixels[dst + 2] = data[src]; // b
                    pixels[dst + 3] = data[src + 3]; // a
                },
            }
        }
    }

    return Image{
        .extent = .{
            .width = hdr.width,
            .height = hdr.height,
            .depth = 1,
        },
        .pixel_format = switch (hdr.n_channels) {
            3 => .rgb_srgb,
            4 => .rgba_srgb,
        },
        .pixels = switch (hdr.n_channels) {
            3 => .{ .rgb = pixels },
            4 => .{ .rgba = pixels },
        },
    };
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
    none = 0,
    rle8 = 1,
    rle4 = 2,
    bitfields = 3,
};

const Header = struct {
    pub const SIG: []const u8 = "BM";
    pixel_data_offset: u32,
    dib_header_size: u32,
    width: u32,
    height: u32,
    is_top_down: bool = false,
    bits_per_pixel: u32,
    n_channels: u32,
    compression: Compression,
    n_colors: u32,
    color_table: [][]u8,
    table_offset: u32,
    table_size: u32,
    n_pixels_per_row: u32,

    pub fn init(r: *std.Io.Reader, gpa: std.mem.Allocator) !@This() {
        var data = try r.readAlloc(gpa, 54);
        try isSigSame(data[0..2], SIG);
        const pixel_data_offset = std.mem.readInt(u32, data[10..][0..4], .little);

        const dib_header_size = std.mem.readInt(u32, data[14..][0..4], .little);
        if (dib_header_size < 40)
            return Error.Decode.InvalidHeader;

        const raw_width = std.mem.readInt(i32, data[18..][0..4], .little);
        const raw_height = std.mem.readInt(i32, data[22..][0..4], .little);
        const width: u32 = @intCast(@max(@as(i32, 0), raw_width));
        const height: u32 = @intCast(@abs(raw_height));
        if (width == 0 or height == 0)
            return Error.Decode.InvalidDimensions;
        const is_top_down: bool = height < 0;

        const bits_per_pixel = std.mem.readInt(u16, data[28..][0..2], .little);
        const n_channels: u32 = switch (bits_per_pixel) {
            8 => 3,
            24 => 3,
            32 => 4,
            else => return Error.Decode.UnsupportedBitsPerPixel,
        };

        const compression = std.enums.fromInt(
            Compression,
            std.mem.readInt(u32, data[30..][0..4], .little),
        ) orelse return Error.Decode.UnsupportedCompression;
        if (compression != .none)
            return Error.Decode.UnsupportedCompression;

        // color table
        const n_colors: u32 = switch (n_channels) {
            1 => 1,
            4 => 16,
            8 => 256,
            16 => 65536,
            24 => 16_000_000,
        };
        var color_table = try gpa.alloc([n_channels]u8, n_colors);
        for (color_table) |*ct| ct.* = try gpa.alloc(u8, n_channels);
        const table_offset: usize = 14 + dib_header_size;
        const table_size: usize = n_colors * n_channels;

        if (data.len < table_offset + table_size)
            return Error.Decode.UnexpectedEndOfData;

        for (0..n_colors) |i| {
            const entry_offset = table_offset + i * 4;
            // stored bgr
            color_table[i] = .{
                data[entry_offset + 2], // r
                data[entry_offset + 1], // g
                data[entry_offset + 0], // b
            };
        }

        const n_pixels_per_row = (width * bits_per_pixel + 31) / 8;

        if (data.len < pixel_data_offset + n_pixels_per_row * height)
            return Error.Decode.UnexpectedEndOfData;

        return .{
            .pixel_data_offset = pixel_data_offset,
            .dib_header_size = dib_header_size,
            .width = width,
            .height = width,
            .is_top_down = is_top_down,
            .bits_per_pixel = bits_per_pixel,
            .n_channels = n_channels,
            .compression = compression,
            .n_colors = n_colors,
            .color_table = color_table,
            .table_offset = table_offset,
            .table_size = table_size,
            .n_pixels_per_row = n_pixels_per_row,
        };
    }

    pub fn deinit(hdr: *const @This(), gpa: std.mem.Allocator) !void {
        for (hdr.color_table) |*ct| gpa.free(ct.*);
        gpa.free(hdr.color_table);
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
