const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const Image = @import("Image.zig").Image2D;

/// need to handle p3 case
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
    _ = w;
    _ = img;
}

const Header = struct {
    pub fn read(r: *std.Io.Reader) !void {
        const sig = try r.take(2);
        try isSigSame(sig, "P6");
    }

    pub fn write(w: *std.Io.Writer) void {
        try w.write("P6");
    }
};

const Body = struct {
    pub fn read(r: *std.Io.Reader) void {
        _ = r;
    }

    pub fn write(w: *std.Io.Writer) void {
        _ = w;
    }
};
