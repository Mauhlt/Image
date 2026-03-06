const std = @import("std");
const Image = @import("Image.zig").Image2D;
const isSigSame = @import("Misc.zig").isSigSame;
const BMP = @This();

pub fn read(
    r: *std.Io.Reader,
    allo: std.mem.Allocator,
) !Image {
    const hdr: Header = try .read(r);
    const body: Body = try .read(r, allo, &hdr);
    return Image{
        .width = hdr.width,
        .height = hdr.height,
        .data = body.data,
    };
}

pub fn write(w: *std.Io.Writer, img: *const Image) !void {
    try Header.write(w, img);
    try Body.write(w, img);
}

const Header = struct {
    const exp_sig: []const u8 = "BM";
    // hdr - 14 bytes
    file_size: u32,
    reserved: u32,
    offset: u32,
    // infohdr - 40 bytes
    ih_size = u32,
    width: u32,
    height: u32,
    planes: u32,
    bits_per_pixel: u16,
    compression: u32,
    image_size: u32,
    x_pixels_per_mm: u32,
    y_pixels_per_mm: u32,
    colors_used: u32,
    important_colors: u32,
    // color table
    color_table: [4]u8,

    pub fn read(r: *std.Io.Reader) !Header {
        // 14 bytes
        const sig = try r.take(2);
        try isSigSame(sig, exp_sig);
        const size = try r.takeInt(u32, .little);
        const reserved = try r.takeInt(u32, .little);
        const offset = try r.takeInt(u32, .little);

        // 40 bytes
        const ih_size = try r.taketInt(u32, .little);
        const width = try r.takeInt(u32, .little);
        const height = try r.takeInt(u32, .little);
        const planes = try r.takeInt(u16, .little);
        const bits_per_pixel = try r.takeInt(u16, .little);
        const compression = try r.takeInt(u32, .little);
        const image_size = try r.takeInt(u32, .little);
        const x_pixels_per_mm = try r.takeInt(u32, .little);
        const y_pixels_per_mm = try r.takeInt(u32, .little);
        const colors_used = try r.takeInt(u32, .little);
        const important_colors = try r.takeInt(u32, .little);

        // color table
        const color_table = try r.takeArray(4);

        return Header{
            // hdr
            .size = size,
            .reserved = reserved,
            .offset = offset,
            // ih
            .width = width,
            .height = height,
            .planes = planes,
            .bits_per_pixel = bits_per_pixel,
            .compression = compression,
            .image_size = image_size,
            .x_pixels_per_mm = x_pixels_per_mm,
            .y_pixels_per_mm = y_pixels_per_mm,
            .colors_used = colors_used,
            .important_colors = important_colors,
            // color table
            .color_table = color_table,
        };
    }

    pub fn write(w: *std.Io.Writer, img: *const Image) !void {
        // hdr
        const reserved: u32 = 0;
        const offset: u32 = 0;
        try w.writeInt(u32, size, .little);
        try w.writeInt(u32, reserved, .little);
        try w.writeInt(u32, offset, .little);
        // ih
        const planes: u16 = 0;
        const bits_per_pixel: u16 = 8;
        const compression: u16 = 0;
        const x_pixels_per_mm = 0;
        const y_pixels_per_mm = 0;
        const colors_used = 0;
        const important_colors = 0;
        try w.writeInt(u32, img.width, .little);
        try w.writeInt(u32, img.height, .little);
        try w.writeInt(u16, planes, .little);
        try w.writeInt(u16, bits_per_pixel, .little);
        try w.writeInt(u32, compression, .little);
        try w.writeInt(u32, img.width * img.height, .little);
        try w.writeInt(u32, x_pixels_per_mm, .little);
        try w.writeInt(u32, y_pixels_per_mm, .little);
        try w.writeInt(u32, colors_used, .little);
        try w.writeInt(u32, important_colors, .little);
        // color table
        try w.write(u32, @bitCast(colors_table), .little);
    }
};

const Body = struct {
    data: []const @TypeOf(Image.data),

    pub fn read(
        r: *std.Io.Reader,
        allo: std.mem.Allocator,
        hdr: *const Header,
    ) ![]const @TypeOf(Image.data) {
        const len = hdr.image_size;
        const data = try r.readAlloc(allo, len);
        return .{
            .data = data,
        };
    }

    pub fn write(w: *std.Io.Writer, img: *const Image) void {
        try w.writeAll(img.data);
    }
};
