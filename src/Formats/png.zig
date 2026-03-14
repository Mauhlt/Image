const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const Image = @import("Image.zig");

pub fn read(gpa: std.mem.Allocator, data: []const u8) !Image {
    const hdr = try .decode(gpa, data);
    const body = try .decode(gpa, &hdr, data);
    _ = body;
    return Image{
        .extent = .{
            .width = hdr.width,
            .height = hdr.height,
            .depth = 1,
        },
        .pixel_format = .r8g8b8a8_srgb,
        .pixels = pixels,
    };
}

pub fn write(self: *const @This(), w: *std.Io.Writer) void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const ColorType = enum(u8) {
    gray = 0,
    true = 1,
    index = 3,
    gray_alpha = 4,
    true_alpha = 6,
};

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    interlace: u8,

    pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !@This() {
        _ = r;
        _ = allo;
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }
};

// const Body = union(enum) {
//     rgb: [*]RGB,
//     rgba: [*]RGBA,
//
//     pub fn read(
//         r: *std.Io.Reader,
//         gpa: std.mem.Allocator,
//         hdr: *const Header,
//     ) !@This() {
//         _ = r;
//         const data = try gpa.alloc(RGBA, hdr.width * hdr.height);
//         defer gpa.free(data);
//     }
//
//     pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
//         try w.writeAll(self.data);
//     }
// };
