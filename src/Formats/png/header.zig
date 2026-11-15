const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Chunk = @import("chunk.zig");

/// The IHDR rules live in Image.check (shared with the pre-decode checker).
const ihdr = @import("ImageCheck").png;

/// Matches same enum names as pixels
pub const ColorType = ihdr.ColorType;
/// Bits per color
pub const BitDepth = ihdr.BitDepth;

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

pub const InterlaceMethod = ihdr.InterlaceMethod;

width: u32, // 4
height: u32, // 8
bit_depth: BitDepth, // 9
color_type: ColorType, // 10
compression_method: CompressionMethod, // 11
filter_method: FilterMethod, // 12
interlace_method: InterlaceMethod, // 13

/// Bits per pixel in the (filtered) data stream.
pub fn bitsPerPixel(self: *const @This()) usize {
    return @as(usize, self.color_type.channels()) * @backingInt(self.bit_depth);
}

/// Bytes per scanline, excluding the filter byte.
pub fn rowBytes(self: *const @This()) usize {
    return self.rowBytesFor(self.width);
}

/// Bytes per scanline of `width` pixels (an interlace pass is narrower than the image).
pub fn rowBytesFor(self: *const @This(), width: usize) usize {
    return (width * self.bitsPerPixel() + 7) / 8;
}

pub fn decode(chunk: Chunk) !@This() {
    if (chunk.tag != .IHDR) return Error.MissingIhdr;
    if (chunk.data.len != 13) return Error.InvalidHeaderLen;
    const width = std.mem.readInt(u32, chunk.data[0..][0..4], .big);
    const height = std.mem.readInt(u32, chunk.data[4..][0..4], .big);
    _, const overflow = @mulWithOverflow(width, height);
    if (overflow > 0) return Error.Overflow;
    const h = ihdr.Header.parse(chunk.data) catch |e| return switch (e) {
        error.InvalidBitDepth => Error.UnsupportedBitsPerPixel,
        error.InvalidColorType => Error.UnsupportedColorspace,
        error.InvalidCompression => Error.UnsupportedCompression,
        error.InvalidFilterMethod => Error.UnsupportedFilterMethod,
        error.InvalidInterlaceMethod => Error.UnsupportedInterlaceMethod,
        error.InvalidDimensions => Error.InvalidDimensions,
        else => Error.InvalidHeader,
    };
    return .{
        .width = h.width,
        .height = h.height,
        .bit_depth = h.bit_depth,
        .color_type = h.color_type,
        .compression_method = .none,
        .filter_method = .none,
        .interlace_method = h.interlace_method,
    };
}

pub fn fromImage(img: *const Image) @This() {
    return .{
        .width = img.width,
        .height = img.height,
        .bit_depth = if (img.pixels == .g16) .bit16 else .bit8,
        .color_type = switch (img.pixels) {
            .g, .g16 => .g,
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
    buf[8] = @backingInt(self.bit_depth);
    buf[9] = @backingInt(self.color_type);
    buf[10] = @backingInt(self.compression_method);
    buf[11] = @backingInt(self.filter_method);
    buf[12] = @backingInt(self.interlace_method);
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
        @as(BitDepth, @fromBackingInt(@intCast(buf[8]))),
        @as(ColorType, @fromBackingInt(@intCast(buf[9]))),
        @as(CompressionMethod, @fromBackingInt(@intCast(buf[10]))),
        @as(FilterMethod, @fromBackingInt(@intCast(buf[11]))),
        @as(InterlaceMethod, @fromBackingInt(@intCast(buf[12]))),
    });
}
