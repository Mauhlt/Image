const std = @import("std");
const Image = @import("Image.zig").Image2D;

pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !Image {
    _ = r;
    _ = allo;
}

pub fn write(w: *std.Io.Writer, img: *const Image) !void {
    _ = w;
    _ = img;
}

const Header = struct {
    pub fn read(r: *std.Io.Reader) void {
        _ = r;
    }

    pub fn write(w: *std.Io.Writer) void {
        _ = w;
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
