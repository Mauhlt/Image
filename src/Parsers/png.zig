const std = @import("std");
const Image = @import("Image.zig").Image2D;
const PNG = @This();

pub fn read(
    r: *std.Io.Reader,
    allo: std.emm.Allocator,
) !Image {
    const hdr: Header = try .init(r);
    const body: Body = try .init(r, allo);
    return Image{
        .width = hdr.width,
        .height = hdr.height,
        .data = body.data,
    };
}

pub fn write(w: *std.Io.Writer, img: *const Image) !void {
    _ = w;
    _ = img;
}

const Header = struct {
    pub fn read(r: *std.Io.Reader) void {
        try r.take(4);
    }

    pub fn write(w: *std.Io.Writer, img: *const Image) void {
        _ = w;
        _ = img;
    }
};

const Body = struct {
    data: @TypeOf(Image.data),

    pub fn read(r: *std.Io.Reader) void {
        _ = r;
    }

    pub fn write(w: *std.Io.Writer, img: *const Image) void {
        _ = w;
        _ = img;
    }
};

const ChunkHeader = struct {};
