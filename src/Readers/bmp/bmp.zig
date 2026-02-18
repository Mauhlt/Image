const std = @import("std");
const testing = std.testing;

const Header = @import("Header.zig");
const Color = @import("../Color.zig");
const Compression = @import("misc.zig").Compression;
const DecodeError = @import("misc.zig").DecodeError;

pub const BmpImage = struct {
    header: Header,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn getPixel(self: *const @This(), x: u32, y: u32) Color {
        const channels: u32 = if (self.header.bits_per_pixel == 32) 4 else 3;
        const idx = (y * self.header.width + x) * channels;
        return .{
            .r = self.pixels[idx],
            .g = self.pixels[idx + 1],
            .b = self.pixels[idx + 2],
            .a = if (channels == 4) self.pixels[idx + 3] else 0xFF,
        };
    }
};

pub fn decode(data: []const u8, allocator: std.mem.Allocator) !BmpImage {
    if (data.len < 54) return DecodeError.InvalidSignature;

    if (data[0] != 'B' or data[1] != 'M')
        return DecodeError.InvalidSignature;

    const pixel_data_offset = std.mem.readInt(u32, data[10..14], .little);

    const dib_header_size = std.mem.readInt(u32, data[14..18], .little);
    if (dib_header_size < 40) return DecodeError.InvalidSignature;

    const raw_width = std.mem.readInt(i32, data[18..22], .little);
    const raw_height = std.mem.readInt(i32, data[22..26], .little);
    const bits_per_pixel = std.mem.readInt(u16, data[28..30], .little);
    const compression_val = std.mem.readInt(u32, data[30..34], .little);

    if (raw_width <= 0 or raw_height <= 0) return DecodeError.InvalidSignature;

    const compression = std.meta.intToEnum(Compression, compression_val) catch
        return DecodeError.UnsupportedCompression;
    switch (compression) {
        .none => {},
        else => return DecodeError.UnsupportedCompression,
    }

    const out_channels: u32 = switch (bits_per_pixel) {
        8, 24 => 3,
        32 => 4,
        else => return DecodeError.UnsupportedBitsPerPixel,
    };

    var color_table: [256][4]u8 = undefined;
}
