const std = @import("std");
const Error = @import("../error.zig").Error;
const misc = @import("misc.zig");
const BitsPerPixel = misc.BitsPerPixel;
const Compression = misc.Compression;

file_size: u32,
data_offset: u32,
dib_hdr_size: u32 = misc.INFO_HDR_SIZE,
width: u32,
height: u32,
is_top_down: bool = false,
bits_per_pixel: BitsPerPixel,
compression: Compression = .none,
image_size: u32,
n_colors_used: u32 = 0,
/// raw BGRX palette entries (4 bytes each), empty for 16/24/32-bit
palette: []const u8 = &.{},

pub fn rowBytes(self: *const @This()) usize {
    return (@as(usize, self.width) * @intFromEnum(self.bits_per_pixel) + 7) / 8;
}

pub fn stride(self: *const @This()) usize {
    return misc.strideOf(self.rowBytes());
}

pub fn paletteLen(self: *const @This()) usize {
    return self.palette.len / 4;
}

/// true if palette[i] == (i, i, i) for every entry -> image is grayscale
pub fn isGrayPalette(self: *const @This()) bool {
    if (self.paletteLen() == 0) return false;
    for (0..self.paletteLen()) |i| {
        const e = self.palette[i * 4 ..][0..3];
        if (e[0] != i or e[1] != i or e[2] != i) return false;
    }
    return true;
}

pub fn decode(data: []const u8) Error!@This() {
    if (data.len < misc.FILE_HDR_SIZE + misc.INFO_HDR_SIZE) return Error.UnexpectedEndOfData;
    if (!std.mem.startsWith(u8, data, misc.SIG)) return Error.UnexpectedSignature;
    const file_size = std.mem.readInt(u32, data[2..6], .little);
    const data_offset = std.mem.readInt(u32, data[10..14], .little);
    const dib_hdr_size = std.mem.readInt(u32, data[14..18], .little);
    // BITMAPINFOHEADER and its V2..V5 extensions share the first 40 bytes
    if (dib_hdr_size < misc.INFO_HDR_SIZE) return Error.InvalidHeaderLen;
    const raw_width = std.mem.readInt(i32, data[18..22], .little);
    const raw_height = std.mem.readInt(i32, data[22..26], .little);
    if (raw_width <= 0 or raw_height == 0 or raw_height == std.math.minInt(i32)) return Error.InvalidDimensions;
    const planes = std.mem.readInt(u16, data[26..28], .little);
    if (planes != 1) return Error.InvalidHeader;
    const bits_per_pixel = std.enums.fromInt(BitsPerPixel, std.mem.readInt(u16, data[28..30], .little)) orelse
        return Error.InvalidBitsPerPixel;
    const compression = std.enums.fromInt(Compression, std.mem.readInt(u32, data[30..34], .little)) orelse
        return Error.InvalidCompression;
    switch (compression) {
        .none => {},
        // bitfields: only the common masks are supported (checked by the decoder via bit depth)
        .bitfields => if (bits_per_pixel != .rgba_32) return Error.UnsupportedCompression,
        .rle4, .rle8 => return Error.UnsupportedCompression,
    }
    if (bits_per_pixel == .rgb_16) return Error.UnsupportedBitsPerPixel;
    const image_size = std.mem.readInt(u32, data[34..38], .little);
    const n_colors_used = std.mem.readInt(u32, data[46..50], .little);

    var hdr: @This() = .{
        .file_size = file_size,
        .data_offset = data_offset,
        .dib_hdr_size = dib_hdr_size,
        .width = @intCast(raw_width),
        .height = @intCast(@abs(raw_height)),
        .is_top_down = raw_height < 0,
        .bits_per_pixel = bits_per_pixel,
        .compression = compression,
        .image_size = image_size,
        .n_colors_used = n_colors_used,
    };

    if (@intFromEnum(bits_per_pixel) <= 8) {
        const max_colors = @as(u32, 1) << @intCast(@intFromEnum(bits_per_pixel));
        const n = if (n_colors_used == 0) max_colors else n_colors_used;
        if (n > max_colors) return Error.InvalidNumberOfColors;
        // BI_BITFIELDS with a 40-byte header stores 3 masks before the palette
        const start = misc.FILE_HDR_SIZE + dib_hdr_size;
        if (start + n * 4 > data.len) return Error.UnexpectedEndOfData;
        hdr.palette = data[start..][0 .. n * 4];
    }

    const end = @as(usize, data_offset) + hdr.stride() * hdr.height;
    if (data_offset < misc.FILE_HDR_SIZE + misc.INFO_HDR_SIZE or end > data.len) return Error.InvalidDataOffset;
    return hdr;
}

/// Uncompressed BITMAPINFOHEADER for 8 (gray palette), 24 or 32-bit pixels.
pub fn init(width: u32, height: u32, bits_per_pixel: BitsPerPixel) Error!@This() {
    if (width == 0 or height == 0 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
        return Error.InvalidDimensions;
    var hdr: @This() = .{
        .file_size = 0,
        .data_offset = 0,
        .width = width,
        .height = height,
        .bits_per_pixel = bits_per_pixel,
        .image_size = 0,
        .n_colors_used = if (bits_per_pixel == .bit_8_palette) 256 else 0,
    };
    const palette_bytes: usize = if (bits_per_pixel == .bit_8_palette) 256 * 4 else 0;
    const image_size = hdr.stride() * height;
    const total = misc.FILE_HDR_SIZE + misc.INFO_HDR_SIZE + palette_bytes + image_size;
    if (total > std.math.maxInt(u32)) return Error.InvalidDimensions;
    hdr.data_offset = @intCast(misc.FILE_HDR_SIZE + misc.INFO_HDR_SIZE + palette_bytes);
    hdr.image_size = @intCast(image_size);
    hdr.file_size = @intCast(total);
    return hdr;
}

/// Writes the file header + BITMAPINFOHEADER (+ gray palette for 8-bit).
pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
    try w.writeAll(misc.SIG);
    try w.writeInt(u32, self.file_size, .little);
    try w.writeInt(u32, 0, .little); // reserved
    try w.writeInt(u32, self.data_offset, .little);
    try w.writeInt(u32, misc.INFO_HDR_SIZE, .little);
    try w.writeInt(i32, @intCast(self.width), .little);
    try w.writeInt(i32, @intCast(self.height), .little); // bottom-up
    try w.writeInt(u16, 1, .little); // planes
    try w.writeInt(u16, @intFromEnum(self.bits_per_pixel), .little);
    try w.writeInt(u32, @intFromEnum(Compression.none), .little);
    try w.writeInt(u32, self.image_size, .little);
    try w.writeInt(i32, 2835, .little); // 72 dpi
    try w.writeInt(i32, 2835, .little);
    try w.writeInt(u32, self.n_colors_used, .little);
    try w.writeInt(u32, 0, .little); // important colors
    if (self.bits_per_pixel == .bit_8_palette) {
        for (0..256) |i| {
            const v: u8 = @intCast(i);
            try w.writeAll(&.{ v, v, v, 0 });
        }
    }
}

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    try w.print("File Size: {}\n", .{self.file_size});
    try w.print("Data Offset: {}\n", .{self.data_offset});
    try w.print("Width: {}\nHeight: {}\nTop Down: {}\n", .{ self.width, self.height, self.is_top_down });
    try w.print("Bits Per Pixel: {t}\nCompression: {t}\n", .{ self.bits_per_pixel, self.compression });
    try w.print("Palette Entries: {}\n", .{self.paletteLen()});
}
