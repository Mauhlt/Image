const std = @import("std");
const isSigSame = @import("Misc.zig").isSigSame;
const RGB = @import("Image.zig").RGB;
const RGBA = @import("Image.zig").RGBA;

hdr: Header,
body: Body,

pub fn read(self: *@This(), r: *std.Io.Reader, allo: *const std.mem.Allocator) !void {
    self.hdr = try .read(r);
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

    pub fn read(r: *std.Io.Reader) !@This() {
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

        const value: u32, const overflow: u1 = @mulWithOverflow(self.width, self.height);
        if (overflow > 0) return error.InvalidDimensions;
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try w.print("{any}\n", .{self.*});
    }
};

const Body = struct {
    pub fn readRGBA(
        self: *const @This(),
        r: *std.Io.Reader,
        allo: *const std.mem.Allocator,
        hdr: *const Header,
    ) !@This() {
        var buf: [4096]u8 = undefined;
        try r.readSliceAll(&buf);
        const len = hdr.width * hdr.height;
        var raw = try r.readAlloc(allo, len);
        var data = try allo.alloc(RGBA, hdr.width * hdr.height * @intFromEnum(hdr.channels));
        // array of previous seen pixels, color channels = assumed to be un-premultiplied alpha
        var previous_pixel: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
        var running_array: [64]RGBA = [_]RGBA{ .r = 0, .g = 0, .b = 0, .a = 0 } ** 64;
        // run of previous pixel,
        // index into array of previously seen pixels,
        // a diff to previous pixel value in rgb
        // full rgb or rgba values
    }

    pub fn readRGB(self: *const @This(), r: *std.Io.Reader, hdr: *const Header) !@This() {
        _ = self;
        _ = r;
        _ = hdr;
        var previous_pixel: RGB = .{ .r = 0, .g = 0, .b = 0 };
        var running_array: [64]RGB = [_]RGB{.{ .r = 0, .g = 0, .b = 0 }} ** 64;
    }

    pub fn write(self: *const @This(), w: *std.Io.Writer) !void {
        _ = self;
        _ = w;
    }

    pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
        try w.print("{}\n", .{self.*});
    }
};

fn hash(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

const Bit64Tags = enum(u64) {
    end = 0b0100000000000000,
};

const Bit8Tags = enum(u64) {
    rgb = 0b11111110,
    rgba = 0b11111111,
};

const Bit2Tags = enum(u8) {
    index = 0b00,
    diff = 0b01,
    luma = 0b10,
    run = 0b11,
};
