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
    const hdr: Header = try .init(r, gpa);
    defer hdr.deinit(gpa);

    return .{};
}

const Header = struct {
    pub const SIG = "BM";
    file_size: u32,
    data_offset: u32,
    width: u32,
    height: u32,
    depth: u32,
    is_top_down: bool,
    bits_per_pixel: BitsPerPixel,
    n_possible_colors: u32,
    compression: Compression,
    compressed_image_size: u32,
    n_colors_used: u32,
    important_colors: u32,
    color_table: [][]u8,

    pub fn read(r: *std.Io.Reader, gpa: std.mem.Allocator) !void {
        const header_data = try r.readAlloc(gpa, 14);
        defer gpa.free(header_data);

        const sig = header_data[0..2];
        try isSigSame(sig, SIG);
        const file_size = std.mem.readInt(u32, header_data[2..][0..4], .little);
        const data_offset = std.mem.readInt(u32, header_data[6..][0..4], .little);
        const dib_hdr_size = std.mem.readInt(u32, header_data[10..][0..4], .little);
        if (dib_hdr_size != 40) return Error.Decode.InvalidHeader;

        const info_header_data = try r.readAlloc(gpa, 54);
        defer gpa.free(info_header_data);
        const raw_width = std.mem.readInt(i32, info_header_data[18..][0..4], .little);
        const raw_height = std.mem.readInt(i32, info_header_data[22..][0..4], .little);
        if (raw_width <= 0 or raw_height == 0) return Error.Decode.InvalidDimensions;
        const width: u32 = @intCast(raw_width);
        const height: u32 = @intCast(@abs(raw_height));
        const is_top_down: bool = raw_height < 0;

        const n_planes = std.mem.readInt(u16, info_header_data[26..][0..2], .little);
        if (n_planes != 1) return Error.Decode.InvalidDimensions;

        const bits_per_pixel = std.enums.fromInt(BitsPerPixel, std.mem.readInt(u32, info_header_data[28..][0..2], .little)) orelse
            return Error.Decode.InvalidBitsPerPixel;
        const n_possible_colors = @as(u32, 1) << @truncate(@as(u32, @intFromEnum(bits_per_pixel)));
        const compression = std.enums.fromInt(Compression, info_header_data[30..][0..4]) orelse
            return Error.Decode.InvalidCompression;
        if (compression != .none) return Error.Decode.InvalidCompression;
        const compressed_image_size = std.mem.readInt(u32, info_header_data[34..][0..4], .little);
        const n_colors_used = std.mem.readInt(u32, info_header_data[42..][0..4], .little);
        const important_colors = std.mem.readInt(u32, info_header_data[46..][0..4], .little);

        const color_table: [][]u8 = switch (bits_per_pixel) {
            .rgb_24, .rgba => &.{},
            else => try gpa.alloc(u8, 10),
        };

        return .{
            .file_size = file_size,
            .data_offset = data_offset,
            .width = width,
            .height = height,
            .depth = n_planes,
            .is_top_down = is_top_down,
            .bits_per_pixel = bits_per_pixel,
            .n_possible_colors = n_possible_colors,
            .compression = compression,
            .compressed_image_size = compressed_image_size,
            .n_colors_used = n_colors_used,
            .important_colors = important_colors,
            .color_table = color_table,
        };
    }
};

const BitsPerPixel = enum {
    monochrome = 1,
    bit_4_pallet = 4,
    bit_8_pallet = 8,
    rgb_16 = 16,
    rgb_24 = 24,
    rgba = 32,
};

const Compression = enum(u32) {
    none = 0,
    rle8 = 1,
    rle4 = 2,
};
