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

    const data: []u8 = try r.readAlloc(gpa, hdr.compressed_image_size);
    errdefer gpa.free(data);
    const pixels: BitType = blk: switch (hdr.bits_per_pixel) {
        .bit_4_pallet, .bit_8_pallet, .rgb_16, .rgb_24 => {
            switch (hdr.compression) {
                .none => break :blk .{ .rgb = @ptrCast(@alignCast(data)) },
                else => unreachable,
            }
        },
        .rgba => {
            switch (hdr.compression) {
                .none => break :blk .{ .rgba = @ptrCast(@alignCast(data)) },
                else => unreachable,
            }
        },
    };

    // parse data here
    return .{
        .extent = .{
            .width = hdr.width,
            .height = hdr.height,
            .depth = hdr.depth,
        },
        .pixel_format = switch (hdr.bits_per_pixel) {
            .monochrome => unreachable,
            .bit_4_pallet, .bit_8_pallet, .rgb_16, .rgb_24 => .r8g8b8_srgb,
            .rgba => .r8g8b8a8_srgb,
        },
        .pixels = pixels,
    };
}

const Header = struct {
    pub const SIG = "BM";
    file_size: u32,
    data_offset: u32,
    dib_hdr_size: u32,
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
    color_table: []RGBA,

    pub fn init(r: *std.Io.Reader, gpa: std.mem.Allocator) !@This() {
        const header_data = try r.readAlloc(gpa, 14);
        defer gpa.free(header_data);
        const sig = header_data[0..2];
        try isSigSame(sig, SIG);
        const file_size = std.mem.readInt(u32, header_data[2..][0..4], .little);
        const data_offset = std.mem.readInt(u32, header_data[10..][0..4], .little);

        const info_header_data = try r.readAlloc(gpa, 40);
        defer gpa.free(info_header_data);
        const dib_hdr_size = std.mem.readInt(u32, info_header_data[0..][0..4], .little);
        if (dib_hdr_size != 40) return Error.Decode.InvalidHeaderLength;
        const raw_width = std.mem.readInt(i32, info_header_data[4..][0..4], .little);
        const raw_height = std.mem.readInt(i32, info_header_data[8..][0..4], .little);
        if (raw_width <= 0 or raw_height == 0) return Error.Decode.InvalidDimensions;
        const width: u32 = @intCast(raw_width);
        const height: u32 = @intCast(@abs(raw_height));
        const is_top_down: bool = raw_height < 0;
        const n_planes = std.mem.readInt(u16, info_header_data[12..][0..2], .little);
        if (n_planes > 1) return Error.Decode.InvalidDimensions;
        const bits_per_pixel = std.enums.fromInt(BitsPerPixel, //
            std.mem.readInt(u16, info_header_data[14..][0..2], .little)) orelse
            return Error.Decode.InvalidBitsPerPixel;
        const n_possible_colors = @as(u32, 1) << //
            @truncate(@as(u32, @intFromEnum(bits_per_pixel)));
        const compression = std.enums.fromInt(Compression, //
            std.mem.readInt(u32, info_header_data[16..][0..4], .little)) orelse
            return Error.Decode.InvalidCompression;
        const compressed_image_size = //
            std.mem.readInt(u32, info_header_data[20..][0..4], .little);
        switch (bits_per_pixel) {
            .rgb_24 => if (compression != .none) return Error.Decode.InvalidCompression,
            else => {},
        }
        const n_colors_used = std.mem.readInt(u32, info_header_data[32..][0..4], .little);
        if (n_colors_used > n_possible_colors) return Error.Decode.InvalidNumOfColors;
        const important_colors = std.mem.readInt(u32, info_header_data[36..][0..4], .little);
        if (important_colors > n_colors_used) return Error.Decode.InvalidImportantColors;

        const colors = try r.readAlloc(gpa, @sizeOf(RGB) * n_colors_used);
        defer gpa.free(colors);
        const color_table: []RGBA = switch (bits_per_pixel) {
            .rgb_24, .rgba => &.{},
            else => try gpa.alloc(RGBA, n_colors_used),
        };
        errdefer gpa.free(color_table);

        return .{
            .file_size = file_size,
            .data_offset = data_offset,
            .dib_hdr_size = dib_hdr_size,
            .width = width,
            .height = height,
            .depth = if (n_planes == 0) 1 else n_planes,
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

    pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
        if (self.color_table.len > 0)
            gpa.free(self.color_table);
    }
};

const BitsPerPixel = enum(u16) {
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
