const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const Error = @import("error.zig");

const GRAY = @import("../Colors/gray.zig");
const GRAYS = @import("../Colors/gray.zig");
const RGB = @import("../Colors/rgb.zig");
const RGBS = @import("../Colors/rgbs.zig");
const RGBA = @import("../Colors/rgba.zig");
const RGBAS = @import("../Colors/rgbas.zig");
const Pixels = @import("../Colors/Pixels.zig");

// http://www.paulbourke.net/dataformats/tga/

const HEADER_SIZE = 18;
const ORIGIN_TOP_LEFT: u8 = 0x20;

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void {
    _ = gpa;
    _ = data;

    // var img: Image = undefined;
    // img.width = width;
    // img.height = height;
    // img.fmt = .rgb;
    // img.pixels = ;
}

// pub fn encode(img: *const Image, w: *std.Io.Writer, maybe_hdr: ?Header) !void {}

const Types = enum(u8) {
    rgb = 2,
    grayscale = 3,
    rle_rgb = 10,
    rle_grayscale = 11,
};

// const Header = struct {
//     id_len: u8,
//     color_map_type: u8,
//     color_map_bytes: usize,
//     img_type: Types,
//     width: u16,
//     height: u16,
//     depth: u8,
//     descriptor: u8,
//     top_left: bool,
//     pixel_offset = pixel_offset,
//
//     pub fn decode(data: []const u8) !@This() {
//         if (data.len < HEADER_SIZE) return Error.Decode.UnexpectedEndOfData;
//         const id_len = data[0];
//
//         const color_map_type = data[1];
//         const color_map_bytes: usize = if (color_map_type == 1) blk: {
//             const entry_count = std.mem.readInt(u16, data[5..][0..2], .little);
//             const entry_size = data[7];
//             break :blk @as(usize, entry_count) * ((entry_size + 7) / 8);
//         } else 0;
//
//         const img_type = std.enums.fromInt(Types, data[2]) orelse
//             return Error.Decode.UnsupportedType;
//         // bytes 3-7 = color map specs
//         // bytes 8-11 = x/y origin
//         const width = std.mem.readInt(u16, data[12..][0..2], .little);
//         const height = std.mem.readInt(u16, data[14..][0..2], .little);
//         if (width == 0 or height == 0) return Error.Decode.InvalidDimensions;
//         const n_pixels, const overflow = @mulWithOverflow(width, height);
//         if (overflow > 0) return Error.Decode.InvalidImageDimensions;
//         const depth = data[16];
//         const descriptor = data[17];
//         const top_left = (descriptor & ORIGIN_TOP_LEFT) != 0;
//
//         switch (img_type) {
//             .rgb, .rle_rgb => {
//                 if (depth != 16 and depth != 24 and depth != 32)
//                     return Error.Decode.UnsupportedDepth;
//             },
//             .grayscale, .rle_grayscale => {
//                 if (depth != 8) return Error.Decode.UnsupportedDepth;
//             },
//         }
//
//         const pixel_offset = HEADER_SIZE + id_len + color_map_bytes;
//
//         return .{
//             .id_len = id_len,
//             .color_map_type = color_map_type,
//             .color_map_bytes = color_map_bytes,
//             .img_type = img_type,
//             .width = width,
//             .height = height,
//             .depth = depth,
//             .descriptor = descriptor,
//             .top_left = top_left,
//             .pixel_offset = pixel_offset,
//         };
//     }
//
//     pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
//         try w.write();
//         try w.flush();
//     }
// };
//
// const Body = struct {
//     // data: []const RGBA, // wastes space
//
//     // pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !@This() {
//     //     _ = r;
//     //     _ = allo;
//     // }
//
//     pub fn write(
//         w: *std.Io.Writer,
//         allo: *const std.mem.Allocator,
//         hdr: *const Header,
//     ) !void {
//         _ = w;
//         _ = allo;
//         _ = hdr;
//     }
// };

// fn uncmompressedData(src: []const u8, pixels: []u8, width: u16, height: u16, depth: u8, top_left: bool) !void {
//     const bpp: usize = depth / 8;
//     if (bpp == 0) return Error.Decode.InvalidBPP;
//     const row_bytes = @as(usize, width) * bpp;
//     if (src.len < @as(usize))
// }
