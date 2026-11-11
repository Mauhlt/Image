const std = @import("std");
const Error = @import("../error.zig").Error;
const misc = @import("misc.zig");
const BitsPerPixel = misc.BitsPerPixel;
const Compression = misc.Compression;
const Masks = @import("bitfields.zig").Masks;

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
/// channel layout of 16/32-bit pixels (defaults for BI_RGB, else from the file)
masks: Masks = .rgb_888,
/// raw palette entries (BGRX, or BGR for OS/2 core headers), empty for 16/24/32-bit
palette: []const u8 = &.{},
palette_entry_size: u8 = 4,

pub fn rowBytes(self: *const @This()) usize {
    return (@as(usize, self.width) * @intFromEnum(self.bits_per_pixel) + 7) / 8;
}

pub fn stride(self: *const @This()) usize {
    return misc.strideOf(self.rowBytes());
}

pub fn paletteLen(self: *const @This()) usize {
    return self.palette.len / self.palette_entry_size;
}

/// BGR of palette entry `i` (caller checks `i < paletteLen()`)
pub fn paletteColor(self: *const @This(), i: usize) *const [3]u8 {
    return self.palette[i * self.palette_entry_size ..][0..3];
}

pub fn hasAlpha(self: *const @This()) bool {
    return self.masks.a != 0;
}

/// true if palette[i] == (i, i, i) for every entry -> image is grayscale
pub fn isGrayPalette(self: *const @This()) bool {
    if (self.paletteLen() == 0) return false;
    for (0..self.paletteLen()) |i| {
        const e = self.paletteColor(i);
        if (e[0] != i or e[1] != i or e[2] != i) return false;
    }
    return true;
}

/// The RLE stream: `image_size` bytes from the data offset, or the rest of the
/// file if that field is 0 (allowed) or too large (seen in the wild).
pub fn rleData(self: *const @This(), data: []const u8) []const u8 {
    const rest = data[self.data_offset..];
    return if (self.image_size == 0) rest else rest[0..@min(rest.len, self.image_size)];
}

pub fn decode(data: []const u8) Error!@This() {
    if (data.len < misc.FILE_HDR_SIZE + 4) return Error.UnexpectedEndOfData;
    if (!std.mem.startsWith(u8, data, misc.SIG)) return Error.UnexpectedSignature;
    const file_size = std.mem.readInt(u32, data[2..6], .little);
    const data_offset = std.mem.readInt(u32, data[10..14], .little);
    const dib_hdr_size = std.mem.readInt(u32, data[14..18], .little);
    // BITMAPINFOHEADER and its V2..V5 extensions share the first 40 bytes
    if (dib_hdr_size != misc.CORE_HDR_SIZE and dib_hdr_size < misc.INFO_HDR_SIZE) return Error.InvalidHeaderLen;
    if (data.len < misc.FILE_HDR_SIZE + @as(usize, dib_hdr_size)) return Error.UnexpectedEndOfData;
    const dib = data[misc.FILE_HDR_SIZE..][0..dib_hdr_size];
    const is_core = dib_hdr_size == misc.CORE_HDR_SIZE;

    // the core header has unsigned 16-bit dimensions (always bottom-up) and no compression
    const raw_width: i32 = if (is_core) std.mem.readInt(u16, dib[4..6], .little) else std.mem.readInt(i32, dib[4..8], .little);
    const raw_height: i32 = if (is_core) std.mem.readInt(u16, dib[6..8], .little) else std.mem.readInt(i32, dib[8..12], .little);
    if (raw_width <= 0 or raw_height == 0 or raw_height == std.math.minInt(i32)) return Error.InvalidDimensions;
    const planes = std.mem.readInt(u16, if (is_core) dib[8..10] else dib[12..14], .little);
    if (planes != 1) return Error.InvalidHeader;
    const bits_per_pixel = std.enums.fromInt(BitsPerPixel, std.mem.readInt(u16, if (is_core) dib[10..12] else dib[14..16], .little)) orelse
        return Error.InvalidBitsPerPixel;
    const compression: Compression = if (is_core) .none else std.enums.fromInt(Compression, std.mem.readInt(u32, dib[16..20], .little)) orelse
        return Error.InvalidCompression;
    const image_size = if (is_core) 0 else std.mem.readInt(u32, dib[20..24], .little);
    const n_colors_used = if (is_core) 0 else std.mem.readInt(u32, dib[32..36], .little);

    const depth_ok = switch (compression) {
        .none => true,
        .rle8 => bits_per_pixel == .bit_8_palette,
        .rle4 => bits_per_pixel == .bit_4_palette,
        .bitfields, .alphabitfields => bits_per_pixel == .rgb_16 or bits_per_pixel == .rgba_32,
    };
    if (!depth_ok) return Error.InvalidCompression;

    var hdr: @This() = .{
        .file_size = file_size,
        .data_offset = data_offset,
        .dib_hdr_size = dib_hdr_size,
        .width = @intCast(raw_width),
        .height = @intCast(@abs(raw_height)),
        // the spec forbids top-down RLE, but Windows decodes it, so we do too
        .is_top_down = raw_height < 0,
        .bits_per_pixel = bits_per_pixel,
        .compression = compression,
        .image_size = image_size,
        .n_colors_used = n_colors_used,
        .masks = if (bits_per_pixel == .rgb_16) .rgb_555 else .rgb_888,
        .palette_entry_size = if (is_core) 3 else 4,
    };

    // Masks always start right after the 40-byte part of the header: V2+ headers
    // contain R, G, B (V3+ also A); a plain 40-byte header is followed by them.
    // V4/V5 headers carry masks even for BI_RGB, where they must be ignored.
    var pal_start: usize = misc.FILE_HDR_SIZE + dib_hdr_size;
    const n_masks: usize = switch (compression) {
        .bitfields => if (dib_hdr_size >= 56) 4 else 3,
        .alphabitfields => 4,
        else => 0,
    };
    if (n_masks > 0) {
        const at = misc.FILE_HDR_SIZE + misc.INFO_HDR_SIZE;
        if (dib_hdr_size == misc.INFO_HDR_SIZE) pal_start += n_masks * 4;
        if (at + n_masks * 4 > data.len) return Error.UnexpectedEndOfData;
        const m = data[at..][0 .. n_masks * 4];
        hdr.masks = .{
            .r = std.mem.readInt(u32, m[0..4], .little),
            .g = std.mem.readInt(u32, m[4..8], .little),
            .b = std.mem.readInt(u32, m[8..12], .little),
            .a = if (n_masks == 4) std.mem.readInt(u32, m[12..16], .little) else 0,
        };
    }
    if (data_offset < pal_start) return Error.InvalidDataOffset;
    switch (compression) {
        .rle4, .rle8 => if (data_offset > data.len) return Error.InvalidDataOffset,
        else => {
            const size = std.math.mul(usize, hdr.stride(), hdr.height) catch return Error.InvalidDimensions;
            const end = std.math.add(usize, data_offset, size) catch return Error.InvalidDimensions;
            if (end > data.len) return Error.InvalidDataOffset;
        },
    }

    if (@intFromEnum(bits_per_pixel) <= 8) {
        const entry: usize = hdr.palette_entry_size;
        const max_colors = @as(usize, 1) << @intCast(@intFromEnum(bits_per_pixel));
        // only 2^bpp entries are addressable, so a larger count (seen in the wild)
        // reads just those; a core header implies a full palette, but some files
        // store fewer entries, so never read into the pixel data
        const wanted = if (n_colors_used == 0) max_colors else @min(n_colors_used, max_colors);
        const n = @min(wanted, (data_offset - pal_start) / entry);
        if (n == 0) return Error.InvalidNumberOfColors;
        hdr.palette = data[pal_start..][0 .. n * entry];
    }
    return hdr;
}

/// BGRA as stored by the encoder: a 32-bit BI_RGB pixel's top byte is unused,
/// so alpha needs BI_BITFIELDS with an alpha mask, which needs a V4+ header
const bgra_masks: Masks = .{ .r = 0x00FF0000, .g = 0x0000FF00, .b = 0x000000FF, .a = 0xFF000000 };
const LCS_SRGB = 0x73524742; // 'sRGB'

/// Uncompressed BITMAPINFOHEADER for 8 (gray palette) or 24-bit pixels,
/// BITMAPV4HEADER with BGRA bitfields for 32-bit.
pub fn init(width: u32, height: u32, bits_per_pixel: BitsPerPixel) Error!@This() {
    if (width == 0 or height == 0 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32))
        return Error.InvalidDimensions;
    const is_bgra = bits_per_pixel == .rgba_32;
    var hdr: @This() = .{
        .file_size = 0,
        .data_offset = 0,
        .dib_hdr_size = if (is_bgra) misc.V4_HDR_SIZE else misc.INFO_HDR_SIZE,
        .width = width,
        .height = height,
        .bits_per_pixel = bits_per_pixel,
        .compression = if (is_bgra) .bitfields else .none,
        .image_size = 0,
        .n_colors_used = if (bits_per_pixel == .bit_8_palette) 256 else 0,
        .masks = if (is_bgra) bgra_masks else .rgb_888,
    };
    const palette_bytes: usize = if (bits_per_pixel == .bit_8_palette) 256 * 4 else 0;
    const image_size = hdr.stride() * height;
    const total = misc.FILE_HDR_SIZE + hdr.dib_hdr_size + palette_bytes + image_size;
    if (total > std.math.maxInt(u32)) return Error.InvalidDimensions;
    hdr.data_offset = @intCast(misc.FILE_HDR_SIZE + hdr.dib_hdr_size + palette_bytes);
    hdr.image_size = @intCast(image_size);
    hdr.file_size = @intCast(total);
    return hdr;
}

/// Writes the file header + DIB header (+ gray palette for 8-bit).
pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
    try w.writeAll(misc.SIG);
    try w.writeInt(u32, self.file_size, .little);
    try w.writeInt(u32, 0, .little); // reserved
    try w.writeInt(u32, self.data_offset, .little);
    try w.writeInt(u32, self.dib_hdr_size, .little);
    try w.writeInt(i32, @intCast(self.width), .little);
    try w.writeInt(i32, @intCast(self.height), .little); // bottom-up
    try w.writeInt(u16, 1, .little); // planes
    try w.writeInt(u16, @intFromEnum(self.bits_per_pixel), .little);
    try w.writeInt(u32, @intFromEnum(self.compression), .little);
    try w.writeInt(u32, self.image_size, .little);
    try w.writeInt(i32, 2835, .little); // 72 dpi
    try w.writeInt(i32, 2835, .little);
    try w.writeInt(u32, self.n_colors_used, .little);
    try w.writeInt(u32, 0, .little); // important colors
    if (self.dib_hdr_size == misc.V4_HDR_SIZE) {
        for ([_]u32{ self.masks.r, self.masks.g, self.masks.b, self.masks.a }) |m| try w.writeInt(u32, m, .little);
        try w.writeInt(u32, LCS_SRGB, .little);
        try w.splatByteAll(0, 36 + 12); // endpoints + gamma, unused for sRGB
    }
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
    try w.print("Masks: R {x} G {x} B {x} A {x}\n", .{ self.masks.r, self.masks.g, self.masks.b, self.masks.a });
    try w.print("Palette Entries: {}\n", .{self.paletteLen()});
}
