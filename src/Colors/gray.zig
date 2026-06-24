const std = @import("std");

const RGB = @import("rgb.zig").RGB;
const RGBA = @import("rgba.zig").RGBA;
const GRAYS = @import("grays.zig");
const GRAY = @This();

g: u8,

pub const Order = enum(u8) {
    g,
};

pub fn init(data: u8) GRAY {
    return .{ .g = data };
}

pub fn toRGB(gray: GRAY) RGB {
    return .{
        .r = gray.g,
        .g = gray.g,
        .b = gray.g,
    };
}

pub fn toRGBA(gray: GRAY) RGBA {
    return .{
        .r = gray.g,
        .g = gray.g,
        .b = gray.g,
        .a = 255,
    };
}

pub fn eql(self: GRAY, other: GRAY) bool {
    return self.g == other.g;
}

test "GRAY" {
    const data: u8 = 255;

    const rgb = init(data).toRGB();
    try std.testing.expectEqualDeep(RGB{ .r = 255, .g = 255, .b = 255 }, rgb);

    const rgba = init(data).toRGBA();
    try std.testing.expectEqualDeep(RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 }, rgba);
}
