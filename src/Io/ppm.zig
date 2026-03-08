const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const RGB = @import("Image.zig").RGB;
const RGBA = @import("Image.zig").RGBA;

hdr: Header,
body: Body,

pub fn read(self: *@This(), r: *std.Io.Reader, allo: *const std.mem.Allocator) !void {
    self.hdr = try .init(r, allo);
    self.body = try .init(r, allo, &self.hdr);
}

pub fn write(self: *@This(), w: *std.Io.Writer) !void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const Header = struct {
    pub fn read(r: *std.Io.Reader, allo: *const std.mem.Allocator) !@This() {}

    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        _ = self;
        _ = w;
    }
};

const Body = struct {
    pub fn read() @This() {}

    pub fn write() void {}
};
