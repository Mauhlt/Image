//! 18-byte TGA header. http://www.paulbourke.net/dataformats/tga/
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
        return @intFromEnum(self) >= 9;
    }

    pub fn base(self: ImageType) ImageType {
        return if (self.isRle()) @enumFromInt(@intFromEnum(self) - 8) else self;
    }
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

pub fn cmapOffset(self: *const @This()) usize {
    return SIZE + @as(usize, self.id_len);
}

pub fn cmapBytes(self: *const @This()) usize {
    if (self.color_map_type != 1) return 0;
    return @as(usize, self.cmap_len) * ((@as(usize, self.cmap_depth) + 7) / 8);
}

pub fn pixelOffset(self: *const @This()) usize {
    return self.cmapOffset() + self.cmapBytes();
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
        // bytes 8..12 = x/y origin (ignored)
        .width = std.mem.readInt(u16, data[12..14], .little),
        .height = std.mem.readInt(u16, data[14..16], .little),
        .depth = data[16],
        .descriptor = data[17],
    };
    if (hdr.width == 0 or hdr.height == 0) return Error.InvalidDimensions;
    if (hdr.color_map_type > 1) return Error.UnsupportedType;
    switch (hdr.image_type.base()) {
        .true_color => if (hdr.depth != 15 and hdr.depth != 16 and hdr.depth != 24 and hdr.depth != 32)
            return Error.UnsupportedDepth,
        .grayscale => if (hdr.depth != 8 and hdr.depth != 16) return Error.UnsupportedDepth,
        .color_mapped => {
            if (hdr.color_map_type != 1 or hdr.depth != 8) return Error.UnsupportedDepth;
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

pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
    var buf: [SIZE]u8 = @splat(0);
    buf[0] = self.id_len;
    buf[1] = self.color_map_type;
    buf[2] = @intFromEnum(self.image_type);
    std.mem.writeInt(u16, buf[12..14], self.width, .little);
    std.mem.writeInt(u16, buf[14..16], self.height, .little);
    buf[16] = self.depth;
    buf[17] = self.descriptor;
    try w.writeAll(&buf);
}
