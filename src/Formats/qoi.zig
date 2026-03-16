const std = @import("std");
const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");
const Image = @import("Image.zig");
const Format = @import("Vulkan").Format;
const isSigSame = @import("Misc.zig").isSigSame;

// TODO:
// - track number of pixels - make sure it matches n_pixels
// - track amount of data left - do not go over

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void { // !Image {
    if (data.len < 14) return error.InvalidData;
    const hdr: Header = try .decode(data);
    const n_pixels = hdr.width * hdr.height;
    const pixel_formats: Format = if (hdr.channels == .rgb and hdr.colorspace == .srgb) .r8g8b8_srgb else //
        if (hdr.channels == .rgb and hdr.colorspace == .linear) .r8b8g8_snorm else //
        if (hdr.channels == .rgba and hdr.colorspace == .srgb) .r8b8g8a8_srgb else //
        .r8b8g8a8_snorm;
    const pixels = try switch (hdr.channels) {
        .rgb => gpa.alloc(RGB, n_pixels),
        .rgba => gpa.alloc(RGBA, n_pixels),
    };

    var img: Image = .{
        .extent = .{
            .width = hdr.width,
            .height = hdr.height,
            .depth = 1,
        },
        .pixels = pixels,
        .pixels_format = pixel_formats,
    };
    defer gpa.free(pixels);

    var prev: RGBA = .{ .r = 0, .g = 0, .b = 0, .a = 0xFF };
    var indices = [_]RGBA{.{ .r = 0, .g = 0, .b = 0, .a = 0xFF }} ** 64;
    var i: usize = 14;

    const len = data.len - 8;
    while (i < len) {
        const b1 = data[i];
        const byte_tag: ByteTag = @enumFromInt(b1);
        switch (byte_tag) {
            .rgb => {
                const tagname = @tagName(byte_tag);
                inline for (0..tagname.len) |j| @field(prev, tagname[j]) = data[i + j + 1];
                i += tagname.len;
            },
            .rgba => {
                const tagname = @tagName(byte_tag);
                inline for (0..tagname.len) |j| @field(prev, tagname[j]) = data[i + j + 1];
                i += tagname.len;
            },
            else => {
                const bit_tag: BitTag = @enumFromInt(b1 >> 6);
                switch (bit_tag) {
                    .index => {
                        const idx: u6 = @truncate(b1);
                        prev = indices[idx];
                        i += 1;
                    },
                    .diff => {
                        prev.r = prev.r +% (b1 >> 4 & 0x03) -% 2;
                        prev.g = prev.g +% (b1 >> 2 & 0x03) -% 2;
                        prev.b = prev.b +% (b1 & 0x03) -% 2;
                        i += 1;
                    },
                    .luma => {
                        const b2 = data[i + 1];
                        const dg = @as(i8, @intCast(b1 & 0x3F)) -% 32;
                        const dr_dg = @as(i8, @intCast(b2 >> 4)) -% 8;
                        const db_dg = @as(i8, @intCast(b2 & 0x0F)) -% 8;
                        const dr = dr_dg +% dg;
                        const db = db_dg +% dg;
                        prev.r = @bitCast(@as(i8, @bitCast(prev.r)) +% dr);
                        prev.g = @bitCast(@as(i8, @bitCast(prev.g)) +% dg);
                        prev.b = @bitCast(@as(i8, @bitCast(prev.b)) +% db);
                        i += 2;
                    },
                    .run => {
                        const n_new_pixels: u8 = (b1 & 0x3F) + 1;
                        std.debug.assert(i + n_new_pixels < n_pixels);
                        switch (img.pixels) {
                            .rgb => |px| @memset(px[i .. i + n_new_pixels], .{ .r = prev.r, .g = prev.g, .b = prev.b }),
                            .rgba => |px| @memset(px[i .. i + n_new_pixels], prev),
                        }
                        // update hash index
                        indices[hash(prev)] = prev;
                    },
                }
            },
        }
    }

    indices[hash(prev)] = prev;
    switch (img.pixels) {
        .rgb => |px| px[i] = .{ .r = prev.r, .g = prev.g, .b = prev.b },
        .rgba => |px| px[i] = prev,
    }

    return img;
}

const ByteTag = enum(u8) {
    rgb = 0xFE,
    rgba = 0xFF,
    _,
};

const BitTag = enum(u2) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

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
