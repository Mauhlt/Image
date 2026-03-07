const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
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

pub fn write(w: *std.Io.Writer) !void {
    _ = w;
}

const Header = struct {
    pub fn read(r: *std.Io.Reader) Header {
        const sig = try r.take(4);
        try isSigSame(sig, "qoif");
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }
};

const Body = struct {
    pub fn read(r: *std.Io.Reader) Body {
        _ = r;
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }
};
