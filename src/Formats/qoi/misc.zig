const RGB = @import("../../Colors/rgb.zig");
const RGBA = @import("../../Colors/rgba.zig");

pub const SIG: []const u8 = "QOIF";
pub const END_MARKER = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const ByteTags = enum(u8) {
    rgb = 254,
    rgba = 255,
    _,
};

pub const BitTags = enum(u2) {
    index = 0,
    diff = 1,
    luma = 2,
    run = 3,
};

pub fn hashRGBA(c: RGBA) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

pub fn hashRGB(c: RGB) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7);
}
