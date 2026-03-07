const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const Image = @import("Image.zig").Image2D;

hdr: Header,
body: Body,

pub fn read(self: *@This(), r: *std.Io.Reader, allo: *const std.mem.Allocator) !@This() {
    self.hdr = try .init(r, allo);
    self.body = try .init(r, allo, &self.hdr);
}

pub fn write(self: *@This(), w: *std.Io.Writer) !void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const Header = struct {};

const Body = struct {};
