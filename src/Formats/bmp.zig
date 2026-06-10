const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("Error.zig");
const Image = @import("img.zig");
const GRAY = @import("color.zig").GRAY;
const RGB = @import("color.zig").RGB;
const RGBA = @import("color.zig").RGBA;
const Pixels = @import("color.zig").Pixels;
const isSigSame = @import("Misc.zig").isSigSame;

const SIG: []const u8 = "BM";

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
    std.debug.print(
        "Start: {}\nEnd: {}\nData Len: {}\n",
        .{ start, end, data.len },
    );
    std.debug.assert(end <= data.len and start <= data.len);
    const pixels_slice = data[start..end];
    const n_pixels = pixels_slice.len / bpp;
    std.debug.assert(n_pixels == exp_n_pixels);
    var pixels: Pixels = undefined;
    var fmt: Format = undefined;
    switch (hdr.bits_per_pixel) {
        .bit_4_pallet, .bit_8_pallet, .rgb_16 => unreachable,
        .monochrome => {
            pixels = try .init(gpa, pixels_slice, .gray, .gray);
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
        .gray => |gray| {
            try w.writeAll(gray);
        },
        .rgb => |rgbs| {
            for (rgbs) |rgb| {
                try w.writeByte(rgb.b);
                try w.writeByte(rgb.g);
                try w.writeByte(rgb.r);
            }
        },
        .rgba => |rgbas| {
            for (rgbas) |rgba| {
                try w.writeByte(rgba.b);
                try w.writeByte(rgba.g);
                try w.writeByte(rgba.r);
                try w.writeByte(rgba.a);
            }
        },
    }
    try w.flush();
}

const Header = struct {
    file_size: u32,
    data_offset: u32 = 54,
    dib_hdr_size: u32 = 40,
    width: u32,
    height: u32,
    depth: u32 = 1,
    is_top_down: bool = false,
    bits_per_pixel: BitsPerPixel = .rgba,
    n_possible_colors: u32,
    compression: Compression = .none,
    compressed_image_size: u32,
    n_colors_used: u32,
    important_colors: u32,
    color_table: Pixels = undefined,

    pub fn fromImage(img: *const Image) !@This() {
        const len, const overflow = @mulWithOverflow(img.width, img.height);
        const bpp: u32 = switch (img.fmt) {
            // .r8_uint => 1,
            // .r4g4b4a4_sint => 2,
            .r8g8b8_srgb => 3,
            .r8g8b8a8_srgb => 4,
            else => return Error.Decode.InvalidFormat,
        };
        if (overflow == 1) return Error.Decode.InvalidDimensions;
        // hdr
        var hdr: Header = undefined;
        hdr.data_offset = 54;
        hdr.file_size = hdr.data_offset + len * bpp;
        // dib
        hdr.dib_hdr_size = 40;
        // img properties
        hdr.width = img.width;
        hdr.height = img.height;
        hdr.depth = 1;
        hdr.is_top_down = false;
        hdr.bits_per_pixel = .rgb_24;
        hdr.compression = .none;
        hdr.compressed_image_size = len * 3;
        hdr.n_possible_colors = @as(u32, 1) << @truncate(@intFromEnum(hdr.bits_per_pixel));
        hdr.n_colors_used = 0;
        hdr.important_colors = 0;
        // return
        return hdr;
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
        // img props
        _, const overflow = @mulWithOverflow(self.width, self.height);
        if (overflow > 0) return Error.Encode.InvalidDimensions;
        // try w.writeInt(u32, self.compressed_image_size, .little);
        try w.writeInt(u32, self.width, .little); // 22
        try w.writeInt(u32, self.height, .little); // 26
        std.debug.assert(self.depth <= 1);
        try w.writeInt(u16, @truncate(self.depth), .little); // 28
        const bpp: u16 = @intFromEnum(self.bits_per_pixel);
        try w.writeInt(u16, bpp, .little); // 30
        std.debug.assert(self.compression == .none);
        const compression: u32 = @intFromEnum(self.compression);
        try w.writeInt(u32, compression, .little); // 34
        try w.writeInt(u32, self.compressed_image_size, .little); // 38
        // TODO: FIXME
        try w.writeInt(u32, 0, .little); // 42
        try w.writeInt(u32, 0, .little); // 46
        try w.writeInt(u32, 0, .little); // 50
        try w.writeInt(u32, 0, .little); // 54
        try w.flush();
    }

    pub fn decode(data: []const u8) !@This() {
        // bmp
        try isSigSame(data[0..2], SIG);
        const file_size = std.mem.readInt(u32, data[2..][0..4], .little);
        if (data.len != file_size)
            return Error.Decode.InvalidDataLength;
        const data_offset = std.mem.readInt(u32, data[10..][0..4], .little);
        // dib
        const dib_hdr_size = std.mem.readInt(u32, data[14..][0..4], .little);
        if (dib_hdr_size != 40)
            return Error.Decode.InvalidHeaderLength;
        const raw_width = std.mem.readInt(i32, data[18..][0..4], .little);
        const raw_height = std.mem.readInt(i32, data[22..][0..4], .little);
        if (raw_width <= 0 or raw_height == 0)
            return Error.Decode.InvalidDimensions;
        const width: u32 = @intCast(raw_width);
        const height: u32 = @intCast(@abs(raw_height));
        const is_top_down: bool = raw_height < 0;
        const depth = std.mem.readInt(u16, data[26..][0..2], .little);
        if (depth > 1) {
            std.debug.print("Depth: {}\n", .{depth});
            return Error.Decode.InvalidDimensions;
        }
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
            return Error.Decode.InvalidNumberOfColors;
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
            // .depth = if (n_planes == 0) 1 else n_planes,
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
        try w.print("\nFile Size: {}\n", .{self.file_size});
        try w.print("Data Offset: {}\n", .{self.data_offset});
        try w.print("Dib Hdr Size: {}\n", .{self.dib_hdr_size});
        try w.print("Width: {}\n", .{self.width});
        try w.print("Height: {}\n", .{self.height});
        // try w.print("Depth: {}\n", .{self.depth});
        try w.print("Top Down: {}\n", .{self.is_top_down});
        try w.print("Bits Per Pixel: {}\n", .{self.bits_per_pixel});
        try w.print("# of Possible Colors: {}\n", .{self.n_possible_colors});
        try w.print("Compression: {t}\n", .{self.compression});
        try w.print("Compressed Image Size: {}\n", .{self.compressed_image_size});
        try w.print("# of Colors Used: {}\n", .{self.n_colors_used});
        // .important_colors = important_colors,
    }
};

const BitsPerPixel = enum(u8) {
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
