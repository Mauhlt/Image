const std = @import("std");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");
const isSigSame = @import("Misc.zig").isSigSame;
// need to

pub fn decode(data: []const u8) !void { // !Image {
    const hdr: Header = try .decode(data);
    std.debug.assert(data.len < (hdr.width * hdr.height));

    // decode chunks
    var prev_pixel: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    const pixel_fields = std.meta.fieldNames(RGBA);
    var pos: usize = 14;
    var pixel_idx: usize = 0;
    var index: usize = 0;

    var i: usize = 14;
    const len = data.len - 8;
    while (i < len) : (i += 1) {
        const b1 = data[i];
        switch (b1) {
            0xFE => {
                inline for (1..4) |j| @field(prev_pixel, pixel_fields[j]) = data[i + j];
                i += 4;
            },
            0xFF => {
                inline for (1..5) |j| @field(prev_pixel, pixel_fields[j]) = data[i + j];
                pos += 5;
            },
            else => {
                const b2: u2 = @truncate(b1 >> 6);
                switch (b2) {
                    0b00 => { // index
                        prev_pixel = index[@truncate(b1)];
                        pos += 1;
                    },
                    0b01 => { // diff
                        const dr: i8 = (@intCast(b1 >> 4) & 0x03) - 2;
                        const dg: i8 = (@intCast(b1 >> 2) & 0x03) - 2;
                        const db: i8 = (@intCast(b1 & 0x03)) - 2;
                        prev_pixel.r +%= dr;
                        prev_pixel.g +%= dg;
                        prev_pixel.b +%= db;
                        pos += 1;
                    },
                    0b10 => {},
                    0b11 => {},
                }
            },
        }
    }
}

pub fn encode() void {}

fn hash(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
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

    pub fn decode(data: []const u8) !@This() {
        isSigSame(data[0..4], "qoif");
        const width = std.mem.readInt(u32, data[4..][0..4], .big);
        const height = std.mem.readInt(u32, data[8..][0..4], .big);
        if (width == 0 or height == 0) return error.InvalidDimensions;
        _, const overflow: u1 = @mulWithOverflow(width, height);
        if (@as(bool, overflow)) return error.InvalidDimensions;
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
