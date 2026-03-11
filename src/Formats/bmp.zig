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
    const bytes = r.readAlloc(gpa, hdr.compressed_image_size) catch |err| blk: switch (err) {
        error.OutOfMemory => {
            std.debug.print(
                "Memory Attempting To Allocate: {}\nWidth: {}\nHeight: {}\nExpected Alloc: {}\n",
                .{ hdr.compressed_image_size, hdr.width, hdr.height, hdr.width * hdr.height },
            );
            const data: []u8 = try gpa.alloc(u8, hdr.width * hdr.height);
            try r.readSliceAll(data);
            break :blk data;
        },
        else => unreachable,
    };
    return .{
        .extent = .{
            .width = hdr.width,
            .height = hdr.height,
            .depth = 1,
        },
        .pixels = switch (hdr.bits_per_pixel) {
            .rgba => .{ .rgba = @as([]RGBA, @ptrCast(@alignCast(bytes))).ptr },
            else => .{ .rgb = @as([]RGB, @ptrCast(@alignCast(bytes))).ptr },
        },
        .pixel_format = .b8g8r8_srgb,
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

    pub fn read(r: *std.Io.Reader, gpa: std.mem.Allocator) !Header {
        var data = try r.readAlloc(gpa, 54);
        try isSigSame(data[0..2], SIG);
        const pixel_data_offset = std.mem.readInt(u32, data[10..][0..4], .little);

        const dib_header_size = std.mem.readInt(u32, data[14..][0..4], .little);
        if (dib_header_size < 40)
            return Error.DecodeError.InvalidHeader;

        const width: u32 = @intCast(@max(0, std.mem.readInt(i32, data[18..][0..4], .little)));
        const height: u32 = @intCast(@abs(std.mem.readInt(i32, data[22..][0..4], .little)));
        if (width == 0 or height == 0)
            return Error.DecodeError.InvalidDimensions;

        const bits_per_pixel = switch (std.mem.readInt(u16, data[28..][0..2], .little)) {
            8 => 3,
            24 => 3,
            32 => 4,
            else => return Error.DecodeError.UnsupportedBitsPerPixel,
        };

        const compression_val = std.enums.fromInt(
            Compression,
            std.mem.readInt(u32, data[30..][0..4], .little),
        ) orelse return Error.DecodeError.UnsupportedCompression;
        if (compression_val != 0) return Error.DecodeError.UnsupportedCompression;

        return .{};
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
