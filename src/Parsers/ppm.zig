const std = @import("std");
const Image = @import("Image.zig").Image2D;

pub fn read(r: *std.Io.Reader) !Image {}

pub fn write(w: *std.Io.Writer, img: *const Image) !void {}

const Header = struct {
    pub fn read(r: *std.Io.Reader) void {}

    pub fn write(w: *std.Io.Writer) void {}
};

const Body = struct {
    pub fn read(r: *std.Io.Reader) void {}

    pub fn write(w: *std.Io.Writer) void {}
};
