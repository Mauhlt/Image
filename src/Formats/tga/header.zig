//! 18-byte TGA header, plus the TGA 2.0 footer / extension area lookup.
//! Spec: Truevision TGA File Format Specification 2.0 (1989).
const std = @import("std");
const Error = @import("../error.zig").Error;

pub const SIZE = 18;

pub const ImageType = enum(u8) {
    color_mapped = 1,
    true_color = 2,
    grayscale = 3,
    rle_color_mapped = 9,
    rle_true_color = 10,
    rle_grayscale = 11,

    pub fn isRle(self: ImageType) bool {
        return @backingInt(self) >= 9;
    }

    pub fn base(self: ImageType) ImageType {
        return if (self.isRle()) @fromBackingInt(@intCast(@backingInt(self) - 8)) else self;
    }
};

/// Extension area field 24 ("Attributes Type"): what the alpha bits of each pixel mean.
pub const AttributeType = enum(u8) {
    no_alpha = 0,
    undefined_ignore = 1,
    undefined_retain = 2,
    alpha = 3,
    premultiplied = 4,
    _, // 5-127 reserved, 128-255 unassigned
};

id_len: u8 = 0,
color_map_type: u8 = 0,
image_type: ImageType,
cmap_first: u16 = 0,
cmap_len: u16 = 0,
cmap_depth: u8 = 0,
width: u16,
height: u16,
depth: u8, // bits per pixel (index size for color-mapped)
descriptor: u8, // bits 0-3 alpha bits, bit 4 right-to-left, bit 5 top-to-bottom

pub fn topDown(self: *const @This()) bool {
    return self.descriptor & 0x20 != 0;
}

pub fn rightToLeft(self: *const @This()) bool {
    return self.descriptor & 0x10 != 0;
}

pub fn alphaBits(self: *const @This()) u4 {
    return @truncate(self.descriptor);
}

/// Bits per stored color: the palette entry size for color-mapped images.
pub fn colorDepth(self: *const @This()) u8 {
    return if (self.image_type.base() == .color_mapped) self.cmap_depth else self.depth;
}

pub fn cmapOffset(self: *const @This()) usize {
    return SIZE + @as(usize, self.id_len);
}

/// Size of the color map field. A map may be present (and must be skipped) even
/// when the image does not use it.
pub fn cmapBytes(self: *const @This()) usize {
    if (self.color_map_type != 1) return 0;
    return @as(usize, self.cmap_len) * bytesFor(self.cmap_depth);
}

pub fn pixelOffset(self: *const @This()) usize {
    return self.cmapOffset() + self.cmapBytes();
}

/// Bytes per stored value; 15-bit values occupy 2 bytes.
pub fn bytesFor(depth: u8) usize {
    return (@as(usize, depth) + 7) / 8;
}

pub fn decode(data: []const u8) Error!@This() {
    if (data.len < SIZE) return Error.UnexpectedEndOfData;
    const hdr: @This() = .{
        .id_len = data[0],
        .color_map_type = data[1],
        .image_type = std.enums.fromInt(ImageType, data[2]) orelse return Error.UnsupportedType,
        .cmap_first = std.mem.readInt(u16, data[3..5], .little),
        .cmap_len = std.mem.readInt(u16, data[5..7], .little),
        .cmap_depth = data[7],
        // bytes 8..12 = x/y origin (screen placement, irrelevant for decoding)
        .width = std.mem.readInt(u16, data[12..14], .little),
        .height = std.mem.readInt(u16, data[14..16], .little),
        .depth = data[16],
        .descriptor = data[17],
    };
    if (hdr.width == 0 or hdr.height == 0) return Error.InvalidDimensions;
    if (hdr.color_map_type > 1) return Error.UnsupportedType;
    switch (hdr.image_type.base()) {
        .true_color => switch (hdr.depth) {
            15, 16, 24, 32 => {},
            else => return Error.UnsupportedDepth,
        },
        .grayscale => if (hdr.depth != 8 and hdr.depth != 16) return Error.UnsupportedDepth,
        .color_mapped => {
            if (hdr.color_map_type != 1 or hdr.cmap_len == 0) return Error.InvalidHeader;
            if (hdr.depth != 8 and hdr.depth != 16) return Error.UnsupportedDepth;
            switch (hdr.cmap_depth) {
                15, 16, 24, 32 => {},
                else => return Error.UnsupportedDepth,
            }
        },
        else => unreachable,
    }
    if (hdr.pixelOffset() > data.len) return Error.UnexpectedEndOfData;
    return hdr;
}

/// Attributes type from the TGA 2.0 extension area, or null for files without one
/// (TGA 1.0 files, or a footer whose extension offset is 0 or out of range).
pub fn attributeType(data: []const u8) ?AttributeType {
    const footer_len = 26;
    const ext_len = 495;
    if (data.len < SIZE + footer_len) return null;
    const footer = data[data.len - footer_len ..];
    if (!std.mem.eql(u8, footer[8..], "TRUEVISION-XFILE.\x00")) return null;
    const offset = std.mem.readInt(u32, footer[0..4], .little);
    if (offset < SIZE or @as(usize, offset) + ext_len > data.len - footer_len) return null;
    const ext = data[offset..][0..ext_len];
    // the area starts with its own size; 495 is the only size the spec defines
    if (std.mem.readInt(u16, ext[0..2], .little) < ext_len) return null;
    return @fromBackingInt(@intCast(ext[494]));
}

pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
    var buf: [SIZE]u8 = @splat(0);
    buf[0] = self.id_len;
    buf[1] = self.color_map_type;
    buf[2] = @backingInt(self.image_type);
    std.mem.writeInt(u16, buf[12..14], self.width, .little);
    std.mem.writeInt(u16, buf[14..16], self.height, .little);
    buf[16] = self.depth;
    buf[17] = self.descriptor;
    try w.writeAll(&buf);
}
