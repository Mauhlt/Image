const std = @import("std");
const Image = @import("Image.zig").Image2D;

pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !Image {
    const hdr: Header = try .init(r);
    const body: Body = try .init(r, allo);
    return Image{
        .width = hdr.width,
        .height = hdr.height,
        .data = body.data,
    };
}

pub fn write(w: *std.Io.Writer, img: *const Image) !void {
    try Header.write(w, img);
    try Body.write(w, img);
}

const Header = struct {
    pub fn read(r: *std.Io.Reader) !Header {
        _ = r;
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }
};

const Body = struct {
    pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !Body {
        _ = r;
        _ = allo;
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }
};
