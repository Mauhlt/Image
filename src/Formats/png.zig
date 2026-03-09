const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");

pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !void {
    const hdr = try .init(r, allo);
    const body = try .init(r, allo, &hdr);
    _ = body;
}

pub fn write(self: *const @This(), w: *std.Io.Writer) void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const Header = struct {
    pub fn read(r: *std.Io.Reader, allo: std.mem.Allocator) !@This() {
        _ = r;
        _ = allo;
    }

    pub fn write(w: *std.Io.Writer) !void {
        _ = w;
    }
};

const Body = struct {
    data: []const RGBA,

    pub fn read(
        r: *std.Io.Reader,
        allo: std.mem.Allocator,
        hdr: Header,
    ) !@This() {
        _ = r;
        const data = try allo.alloc(RGBA, hdr.width * hdr.height);
        defer allo.free(data);
    }

    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        try w.writeAll(self.data);
    }
};
