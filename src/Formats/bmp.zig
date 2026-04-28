const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("Error.zig");
const Image = @import("img.zig");
const RGBA = @import("color.zig").RGBA;
const Pixels = @import("color.zig").Pixels;
const isSigSame = @import("Misc.zig").isSigSame;

// pub const HDR_SIZE = 54;
pub const SIG: []const u8 = "BM";

// https://www.ece.ualberta.ca/~elliott/ee552/studentAppNotes/2003_w/misc/bmp_file_format/bmp_file_format.htm
pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    const hdr: Header = try .decode(data);
    // defer hdr.deinit(gpa);
    std.debug.print("{f}", .{hdr});

    std.debug.assert(hdr.depth == 1);
    const bpp: @TypeOf(hdr.width) = switch (hdr.bits_per_pixel) {
        .monochrome => 1,
        .bit_4_pallet, .bit_8_pallet, .rgb_16, .rgb_24 => 3,
        .rgba => 4,
    };
    const exp_n_pixels = hdr.width * hdr.height;
    const start = hdr.data_offset;
    const end = start + hdr.compressed_image_size;
    std.debug.assert(end <= data.len and start <= data.len);
    const pixels_slice = data[start..end];
    const n_pixels = pixels_slice.len / bpp;
    std.debug.assert(n_pixels == exp_n_pixels);

    var pixels: Pixels = undefined;
    var format: Format = undefined;
    switch (hdr.bits_per_pixel) {
        .bit_4_pallet, .bit_8_pallet, .rgb_16 => unreachable,
        .monochrome => {
            pixels = .{ .gray = try gpa.alloc(@typeInfo(@TypeOf(pixels.gray)).pointer.child, n_pixels) };
            errdefer pixels.gray.deinit(gpa);
            @memcpy(pixels.gray, pixels_slice);
            format = .r8_srgb;
        },
        .rgb_24 => {
            pixels = .{ .rgb = try gpa.alloc(@typeInfo(@TypeOf(pixels.rgb)).pointer.child, n_pixels) };
            var j: usize = 0;
            for (0..n_pixels) |i| {
                pixels.rgb[i] = .{
                    .r = pixels_slice[j + 2],
                    .g = pixels_slice[j + 1],
                    .b = pixels_slice[j],
                };
                j += 3;
            }
            format = .r8g8b8_srgb;
        },
        .rgba => {
            pixels = .{ .rgba = try gpa.alloc(@typeInfo(@TypeOf(pixels.rgba)).pointer.child, n_pixels) };
            var j: usize = 0;
            for (0..n_pixels) |i| {
                pixels.rgba[i] = .{
                    .r = pixels_slice[j + 2],
                    .g = pixels_slice[j + 1],
                    .b = pixels_slice[j],
                    .a = pixels_slice[j + 3],
                };
                j += 4;
            }
            format = .r8g8b8a8_srgb;
        },
    }
    return .{
        .width = hdr.width,
        .height = hdr.height,
        .format = .r8g8b8_srgb,
        .pixels = pixels,
    };
}

pub fn encode(img: *const Image, w: *std.Io.Writer) !void {
    const hdr: Header = try .fromImage(img);
    try hdr.encode(w);

    std.debug.print("Writing: {t}\n", .{img.format});
    switch (hdr.compression) {
        .none => switch (img.format) {
            .r8g8b8_srgb => try img.writeRGB(w),
            .r8g8b8a8_srgb => try img.writeRGBA(w),
            .b8g8r8_srgb => try img.writeBGR(w),
            .b8g8r8a8_srgb => try img.writeBGRA(w),
            else => unreachable,
        },
        .rle4 => {},
        .rle8 => {},
    }
}

const Header = struct {
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
    color_table: Pixels = undefined,

    pub fn fromImage(img: *const Image) !@This() {
        const len, const overflow = @mulWithOverflow(img.width, img.height);
        if (overflow == 1) return error.ImageOverflowed;
        const depth = img.depth();
        if (depth > std.math.maxInt(u16)) return Error.Decode.InvalidDimensions;
        const data_offset: u32 = 54;
        const dib_hdr_size: u32 = 40;

        return .{
            // hdr
            .file_size = data_offset + len * 3,
            .data_offset = data_offset,
            // dib
            .dib_hdr_size = dib_hdr_size,
            .width = img.width,
            .height = img.height,
            .depth = depth,
            .is_top_down = false,
            .bits_per_pixel = .rgb_24,
            .compression = .none,
            .compressed_image_size = len * 3,
            .n_possible_colors = 0,
            .n_colors_used = 0,
            .important_colors = 0,
        };
    }

    pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
        // bmp
        try w.writeAll(SIG); // 2
        try w.writeInt(u32, self.file_size, .little); // 6
        try w.writeInt(u32, 0, .little); // 10
        std.debug.assert(self.data_offset == 54);
        try w.writeInt(u32, self.data_offset, .little); // 14
        // dib
        std.debug.assert(self.dib_hdr_size == 40);
        try w.writeInt(u32, self.dib_hdr_size, .little); // 18
        std.debug.assert(self.width * self.height == self.compressed_image_size);
        try w.writeInt(u32, self.width, .little); // 22
        try w.writeInt(u32, self.height, .little); // 26
        try w.writeInt(u16, @as(u16, @truncate(self.depth)), .little); // 28
        try w.writeInt(u16, @as(u16, @intFromEnum(self.bits_per_pixel)), .little); // 30
        std.debug.assert(self.compression == .none);
        try w.writeInt(u32, @as(u32, @intFromEnum(self.compression)), .little); // 34
        try w.writeInt(u32, self.compressed_image_size, .little); // 38
        try w.writeInt(u32, 0, .little); // 42
        try w.writeInt(u32, 0, .little); // 46
        try w.writeInt(u32, 0, .little); // 50
        try w.writeInt(u32, 0, .little); // 54
    }

    // need file size to understand this
    pub fn decode(data: []const u8) !@This() {
        try isSigSame(data[0..2], SIG);
        const file_size = std.mem.readInt(u32, data[2..][0..4], .little);
        const data_offset = std.mem.readInt(u32, data[10..][0..4], .little);

        const dib_hdr_size = std.mem.readInt(u32, data[14..][0..4], .little);
        if (dib_hdr_size != 40) return Error.Decode.InvalidHeaderLength;
        const raw_width = std.mem.readInt(i32, data[18..][0..4], .little);
        const raw_height = std.mem.readInt(i32, data[22..][0..4], .little);
        if (raw_width <= 0 or raw_height == 0) return Error.Decode.InvalidDimensions;
        const width: u32 = @intCast(raw_width);
        const height: u32 = @intCast(@abs(raw_height));
        const is_top_down: bool = raw_height < 0;
        const n_planes = std.mem.readInt(u16, data[26..][0..2], .little);
        if (n_planes > 1) return Error.Decode.InvalidDimensions;
        const bits_per_pixel = std.enums.fromInt(BitsPerPixel, //
            std.mem.readInt(u16, data[28..][0..2], .little)) orelse
            return Error.Decode.InvalidBitsPerPixel;
        const n_possible_colors = @as(u32, 1) << //
            @truncate(@as(u32, @intFromEnum(bits_per_pixel)));
        const compression = std.enums.fromInt(Compression, //
            std.mem.readInt(u32, data[30..][0..4], .little)) orelse
            return Error.Decode.InvalidCompression;
        const compressed_image_size = //
            std.mem.readInt(u32, data[34..][0..4], .little);
        switch (bits_per_pixel) {
            .rgb_24 => if (compression != .none)
                return Error.Decode.InvalidCompression,
            else => unreachable,
        }
        const n_colors_used = std.mem.readInt(u32, data[46..][0..4], .little);
        if (n_colors_used > n_possible_colors) {
            std.debug.print("# of Colors Used: {}\n", .{n_colors_used});
            std.debug.print("# of Possible Colors: {}\n", .{n_possible_colors});
            return Error.Decode.InvalidNumOfColors;
        }
        const important_colors = std.mem.readInt(u32, data[50..][0..4], .little);
        if (important_colors > n_colors_used) {
            return Error.Decode.InvalidImportantColors;
        }
        switch (bits_per_pixel) {
            .monochrome => {}, // gray
            .bit_4_pallet, .bit_8_pallet, .rgb_16 => {}, // rgb
            .rgb_24 => {}, // rgb
            .rgba => {}, // rgba
        }
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
            // .color_table = color_table,
        };
    }

    pub fn deinit(self: *const Header, gpa: std.mem.Allocator) void {
        if (self.color_table.len > 0) {
            gpa.free(self.color_table);
        }
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try w.print("File Size: {}\n", .{self.file_size});
        try w.print("Data Offset: {}\n", .{self.data_offset});
        try w.print("Dib Hdr Size: {}\n", .{self.dib_hdr_size});
        try w.print("Width: {}\n", .{self.width});
        try w.print("Height: {}\n", .{self.height});
        try w.print("Depth: {}\n", .{self.depth});
        try w.print("Top Down: {}\n", .{self.is_top_down});
        try w.print("Bits Per Pixel: {}\n", .{self.bits_per_pixel});
        try w.print("# of Possible Colors: {}\n", .{self.n_possible_colors});
        try w.print("Compression: {t}\n", .{self.compression});
        try w.print("Compressed Image Size: {}\n", .{self.compressed_image_size});
        try w.print("# of Colors Used: {}\n", .{self.n_colors_used});
        // .important_colors = important_colors,
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
