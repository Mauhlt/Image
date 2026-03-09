const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");

// http://www.paulbourke.net/dataformats/tga/

pub fn read(self: *@This(), r: *std.Io.Reader, allo: std.mem.Allocator) !void {
    self.hdr = try .read(r, allo);
    self.body = try .read(r, allo);
}

pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const Header = struct {
    pub fn read(r: *std.Io.Reader, allo: *const std.mem.Allocator) !@This() {
        _ = r;
        _ = allo;
    }

    pub fn write(w: *std.Io.Writer) void {
        _ = w;
    }
};

const Body = struct {
    data: []const RGBA, // wastes space

    pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !@This() {
        _ = r;
        _ = allo;
    }

    pub fn write(
        w: *std.Io.Writer,
        allo: *const std.mem.Allocator,
        hdr: *const Header,
    ) !void {
        _ = w;
        _ = allo;
        _ = hdr;
    }
};
