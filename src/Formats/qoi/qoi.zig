const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../error.zig");

const Header = @import("header.zig");

const Image = @import("../../root.zig");
const GRAY = @import("../../Colors/gray.zig");
const GRAYS = @import("../../Colors/grays.zig");
const RGB = @import("../../Colors/rgb.zig");
const RGBS = @import("../../Colors/rgbs.zig");
const RGBA = @import("../../Colors/rgba.zig");
const RGBAS = @import("../../Colors/rgbas.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

const isSigSame = @import("Misc.zig").isSigSame;

pub const SIG: []const u8 = "qoif";
pub const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
pub const Colorspace = enum(u8) {
    srgb = 0, // linear alpha
    linear = 1,
};
pub const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};
pub const ByteTags = enum(u8) {
    rgb = 0xFE,
    rgba = 0xFF,
    _,
};
pub const BitTags = enum(u2) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

inline fn hashRGBA(rgba: RGBA) u6 {
    return @truncate(rgba.r *% 3 +% rgba.g *% 5 +% rgba.b *% 7 +% rgba.a *% 11);
}

inline fn hashRGB(rgb: RGB) u6 {
    return @truncate(rgb.r *% 3 +% rgb.g *% 5 +% rgb.b *% 7);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < (@sizeOf(Header) + END_MARKER.len)) return error.InvalidDataLength;
    const hdr: Header = try .decode(data);
    const fmt = blk: {
        var buf: [8]u8 = undefined;
        const fmt = try std.fmt.bufPrint(&buf, "{}_{}\n", .{
            switch (hdr.channel) {
                .rgb => "r8g8b8",
                .rgba => "r8g8b8a8",
            },
            switch (hdr.colorspace) {
                .srgb => "srgb",
                .linear => "unorm",
            },
        });
        break :blk fmt;
    };
    const n_pixels = hdr.width * hdr.height;
    var pixels: Pixels = try .initEmpty(gpa, n_pixels);
    errdefer pixels.deinit(gpa);
    return .{
        .fmt = fmt,
        .width = hdr.width,
        .height = hdr.height,
        .pixels = pixels,
    };
}

pub fn encode() !void {}

fn decodeRGB() !void {}

fn decodeRGBA() !void {}

fn encodeRGB() !void {}

fn encodeRGBA() !void {}
