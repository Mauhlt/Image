const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const Image = @import("Image.zig").Image2D;

hdr: Header,
body: Body,

pub fn read(self: *@This(), r: *std.Io.Reader, allo: *const std.mem.Allocator) !@This() {
    self.hdr = try .read(r, allo);
    self.body = try .read(r, allo, &self.hdr);
}

pub fn write(self: *@This(), w: *std.Io.Writer) !void {
    try self.hdr.write(w);
    try self.body.write(w);
}

const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Header = struct {
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: Colorspace,

    pub fn read(r: *std.Io.Reader, allo: *const std.mem.Allocator) !@This() {
        _ = allo;
        const sig = try r.takeArray(4);
        try isSigSame(sig, "qoif");
        const width = try r.takeInt(u32, .big);
        const height = try r.takeInt(u32, .big);
        const channels = try r.takeEnum(Channels, .big) orelse
            return error.InvalidChannelsEnum;
        const colorspace = try r.takeEnum(Colorspace, .big) orelse
            return error.InvalidColorspaceEnum;
        return .{
            .width = width,
            .height = height,
            .channels = channels,
            .colorspace = colorspace,
        };
    }

    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        try w.writeAll("qoif");
        try w.writeInt(u32, self.width, .big);
        try w.writeInt(u32, self.height, .big);
        try w.writeInt(u8, @intFromEnum(self.channels), .big);
        try w.writeInt(u8, @intFromEnum(self.colorspace), .big);
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) void {}
};

const Body = struct {
    pub fn read(self: *const @This(), r: *std.Io.Reader, hdr: *const Header) !@This() {
        _ = self;
        _ = r;
        _ = hdr;
    }

    pub fn write(self: *const QOI, w: *std.Io.Writer) !void {
        _ = self;
        _ = w;
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        w.print("", .{});
    }
};
