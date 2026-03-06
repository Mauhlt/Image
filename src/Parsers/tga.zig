const std = @import("std");
const Image = @import("Image.zig").Image2D;

pub fn read(r: *std.Io.Reader) !Image {}

pub fn write(img: *const Image, w: *std.Io.Writer) !void {}

const Header = struct {};
const Body = struct {};
