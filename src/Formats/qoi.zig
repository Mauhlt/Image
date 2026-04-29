const std = @import("std");
const Format = @import("Vulkan").Format;
const Image = @import("img.zig");
const RGBA = @import("color.zig").RGBA;
const Pixels = @import("color.zig").Pixels;
const isSigSame = @import("Misc.zig").isSigSame;

// TODO:
// - track number of pixels - make sure it matches n_pixels
// - track amount of data left - do not go over

const SIG = "QOIF";
// const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

fn hash(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void {
    const hdr: Header = try .decode(data);
    std.debug.print("{f}", .{hdr});
    // check end bytes
    std.debug.assert(std.mem.eql(u8, data[data.len - 8 ..], [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 }));

    const pixels_slice = data[14..];
    const n_pixels = hdr.width * hdr.height;
    std.debug.print("# of Pixels: {}\nPixel Slice Len: {}\n", .{ n_pixels, pixels_slice.len });
    const pixels = blk: {
        var pixels: Pixels = undefined;
        switch (hdr.channel) {
            .rgb => {
                pixels = .{ .rgb = try gpa.alloc(@typeInfo(@TypeOf(pixels.rgb)).pointer.child, n_pixels) };
                break :blk pixels;
            },
            .rgba => {
                pixels = .{ .rgba = try gpa.alloc(@typeInfo(@TypeOf(pixels.rgba)).pointer.child, n_pixels) };
                break :blk pixels;
            },
        }
        break :blk pixels;
    };
    defer pixels.deinit(gpa);

    var i: usize = 0;
    var prev_pixel: RGBA = .{};
    while (i < pixels_slice.len) : (i += 1) {
        switch (pixels_slice[i]) {
            0xFE => { // RGB
                prev_pixel.r = pixels_slice[i + 1];
                prev_pixel.g = pixels_slice[i + 2];
                prev_pixel.b = pixels_slice[i + 3];
            },
            0xFF => { // RGBA
                prev_pixel.r = pixels_slice[i + 1];
                prev_pixel.g = pixels_slice[i + 2];
                prev_pixel.b = pixels_slice[i + 3];
                prev_pixel.a = pixels_slice[i + 4];
            },
            else => {
                const byte = pixels_slice[i];
                const bitTag: ByteTags = @enumFromInt(byte >> 6);
                switch (bitTag) {
                    .index => {},
                    .diff => {},
                    .luma => {},
                    .run => {},
                }
            },
        }
    }
}

const ByteTags = enum(u8) {
    rgb = 0b1111_1110,
    rgba = 0b1111_1111,
};

const BitTags = enum(u8) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

pub fn encode() void {}

const Header = struct {
    width: u32,
    height: u32,
    channel: Channel,
    colorspace: Colorspace,

    pub fn fromImage() @This() {}

    pub fn decode(data: []const u8) !@This() {
        std.debug.assert(data.len > 14);
        var i: usize = 0;
        try isSigSame(SIG, data[i..][0..SIG.LEN]);
        i += SIG.LEN;
        const width = std.mem.readInt(u32, data[i..][0..4], .big);
        i += 4;
        const height = std.mem.readInt(u32, data[i..][0..4], .big);
        _, const overflow: u1 = @mulWithOverflow(width, height);
        if (overflow > 0) return error.InvalidDimensions;
        const channel = std.enums.fromInt(Channel, data[i]) orelse
            return error.InvalidChannelValue;
        i += 1;
        const colorspace = std.enums.fromInt(Colorspace, data[i]) orelse
            return error.InvalidColorspaceValue;
        return .{
            .width = width,
            .height = height,
            .channel = channel,
            .colorpace = colorspace,
        };
    }

    pub fn encode() void {}

    pub fn format(self: @This(), w: *std.Io.Writer) void {
        try w.print("Width: {}\n", .{self.width});
        try w.print("Height: {}\n", .{self.height});
        try w.print("Colorspace: {t}\n", .{self.colorspace});
        try w.print("Channels: {t}\n", .{self.channel});
    }
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};
