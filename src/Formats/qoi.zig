const std = @import("std");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");
const isSigSame = @import("Misc.zig").isSigSame;

pub fn decode(data: []const u8) !void { // !Image {
    const hdr: Header = try .decode(data);
    var i: usize = 14;
    while (i < data.len) : (i += 1) {
        switch (data[i]) {
            0xFF => {},
            else => return error.InvalidDecodeSymbol,
        }
    }
}

pub fn encode() void {}

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

    pub fn decode(data: []const u8) !@This() {
        isSigSame(data[0..4], "qoif");
        const width = std.mem.readInt(u32, data[4..][0..4], .big);
        const height = std.mem.readInt(u32, data[8..][0..4], .big);
        const channels = std.enums.fromInt(Channels, data[12]) orelse
            return error.InvalidChannel;
        const colorspace = std.enums.fromInt(Colorspace, data[13]) orelse
            return error.InvalidColorspace;
        return .{
            .width = width,
            .height = height,
            .channels = channels,
            .colorspace = colorspace,
        };
    }

    pub fn encode(self: *const @This(), w: *std.Io.Writer) !void {
        try w.writeAll("qoif");
        try w.writeInt(u32, self.width, .big);
        try w.writeInt(u32, self.height, .big);
        try w.writeInt(u8, @intFromEnum(self.channels), .little);
        try w.writeInt(u8, @intFromEnum(self.colorspace), .little);
    }
};
