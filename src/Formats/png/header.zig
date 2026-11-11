const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Chunk = @import("chunk.zig");

/// Matches same enum names as pixels
pub const ColorType = enum(u8) {
    g = 0,
    rgb = 2,
    i = 3, // palette indices
    ga = 4,
    rgba = 6,

    pub fn channels(self: ColorType) u8 {
        return switch (self) {
            .g, .i => 1,
            .ga => 2,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

/// Bits per color
pub const BitDepth = enum(u8) {
    bit1 = 1,
    bit2 = 2,
    bit4 = 4,
    bit8 = 8,
    bit16 = 16,
};

pub const CompressionMethod = enum(u8) {
    none = 0,
};

pub const FilterMethod = enum(u8) {
    none = 0,
    sub = 1,
    up = 2,
    avg = 3,
    paeth = 4,
};

pub const InterlaceMethod = enum(u8) {
    none = 0,
    adam7 = 1,
};

width: u32, // 4
height: u32, // 8
bit_depth: BitDepth, // 9
color_type: ColorType, // 10
compression_method: CompressionMethod, // 11
filter_method: FilterMethod, // 12
interlace_method: InterlaceMethod, // 13

/// Bits per pixel in the (filtered) data stream.
pub fn bitsPerPixel(self: *const @This()) usize {
    return @as(usize, self.color_type.channels()) * @intFromEnum(self.bit_depth);
}

/// Bytes per scanline, excluding the filter byte.
pub fn rowBytes(self: *const @This()) usize {
    return (@as(usize, self.width) * self.bitsPerPixel() + 7) / 8;
}

pub fn decode(chunk: Chunk) !@This() {
    if (chunk.tag != .IHDR) return Error.MissingIhdr;
    if (chunk.data.len != 13) return Error.InvalidHeaderLen;
    const width = std.mem.readInt(u32, chunk.data[0..][0..4], .big);
    const height = std.mem.readInt(u32, chunk.data[4..][0..4], .big);
    _, const overflow = @mulWithOverflow(width, height);
    if (overflow > 0) return Error.Overflow;
    const bit_depth = std.enums.fromInt(BitDepth, chunk.data[8]) orelse //
        return Error.UnsupportedBitsPerPixel;
    const color_type = std.enums.fromInt(ColorType, chunk.data[9]) orelse //
        return Error.UnsupportedColorspace;
    const compression_method = std.enums.fromInt(CompressionMethod, chunk.data[10]) orelse //
        return Error.UnsupportedCompression;
    const filter_method = std.enums.fromInt(FilterMethod, chunk.data[11]) orelse //
        return Error.UnsupportedFilterMethod;
    const interlace_method = std.enums.fromInt(InterlaceMethod, chunk.data[12]) orelse //
        return Error.UnsupportedInterlaceMethod;
    if (width == 0 or height == 0) return Error.InvalidDimensions;
    // only some (color type, depth) pairs are legal
    const ok = switch (color_type) {
        .g => true,
        .i => @intFromEnum(bit_depth) <= 8,
        .rgb, .ga, .rgba => @intFromEnum(bit_depth) >= 8,
    };
    if (!ok) return Error.UnsupportedBitsPerPixel;
    return .{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .color_type = color_type,
        .compression_method = compression_method,
        .filter_method = filter_method,
        .interlace_method = interlace_method,
    };
}

pub fn fromImage(img: *const Image) @This() {
    return .{
        .width = img.width,
        .height = img.height,
        .bit_depth = .bit8,
        .color_type = switch (img.pixels) {
            .g => .g,
            .ga => .ga,
            .rgb => .rgb,
            .rgba => .rgba,
            .bgr, .ycbcr => .rgb,
            .bgra, .ycbcra => .rgba,
        },
        .compression_method = .none,
        .filter_method = .none,
        .interlace_method = .none,
    };
}

pub fn encode(self: *const @This(), buf: *[13]u8) !void {
    std.mem.writeInt(u32, buf[0..4], self.width, .big);
    std.mem.writeInt(u32, buf[4..8], self.height, .big);
    buf[8] = @intFromEnum(self.bit_depth);
    buf[9] = @intFromEnum(self.color_type);
    buf[10] = @intFromEnum(self.compression_method);
    buf[11] = @intFromEnum(self.filter_method);
    buf[12] = @intFromEnum(self.interlace_method);
}

pub fn format(self: @This(), w: *std.Io.Writer) !void {
    try w.print("Width: {}\n", .{self.width});
    try w.print("Height: {}\n", .{self.height});

    try w.print("Bit Depth: {t}\n", .{self.bit_depth});
    try w.print("Color Type: {t}\n", .{self.color_type});
    try w.print("Compression Method: {t}\n", .{self.compression_method});
    try w.print("Filter Method: {t}\n", .{self.filter_method});
    try w.print("Interlace Method: {t}\n", .{self.interlace_method});
}

pub fn formatBuf(buf: *const [13]u8) !void {
    std.debug.print("{} - {}\n{t}\n{t}\n{t}\n{t}\n{t}\n", .{
        std.mem.readInt(u32, buf[0..4], .big),
        std.mem.readInt(u32, buf[4..8], .big),
        @as(BitDepth, @enumFromInt(buf[8])),
        @as(ColorType, @enumFromInt(buf[9])),
        @as(CompressionMethod, @enumFromInt(buf[10])),
        @as(FilterMethod, @enumFromInt(buf[11])),
        @as(InterlaceMethod, @enumFromInt(buf[12])),
    });
}
