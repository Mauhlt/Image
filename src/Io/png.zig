const std = @import("std");
const RGBA = @import("Image.zig").RGBA;
const Image = @import("Image.zig").Image2DRGBA;
const isSigSame = @import("Misc.zig").isSigSame;

hdr: Header,
body: Body,

pub fn read(self: *@This(), r: *std.Io.Reader, allo: *const std.mem.Allocator) !void {
    self.hdr = try .init(r, allo);
    self.body = try .init(r, allo, &self.hdr);
}

pub fn write(self: *const @This(), w: *std.Io.Writer) void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const Header = struct {
    pub fn read(r: *std.Io.Reader, allo: *const std.mem.Allocator) !@This() {
        _ = r;
        _ = allo;
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) void {
        w.print("{}\n", .{self.*});
    }
};

const Body = struct {
    data: []const RGBA,

    pub fn read(
        r: *std.Io.Reader,
        allo: *const std.mem.Allocator,
        hdr: *const Header,
    ) !@This() {
        _ = r;
        _ = allo;
        _ = hdr;
    }

    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        try w.writeAll(self.data);
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        w.print("{}\n", .{self.data[0]});
    }
};

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    self.hdr.format(w);
    self.body.format(w);
}
