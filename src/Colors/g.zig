const std = @import("std");
const Order = @import("order.zig").Singlets;
const misc = @import("misc.zig");
const G16 = @import("g16.zig").G16;

const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

pub const G = extern struct {
    g: u8,

    pub fn init(data: u8) G {
        return .{ .g = data };
    }

    pub fn toRgb(self: G) RGB {
        return .{
            .r = self.g,
            .g = self.g,
            .b = self.g,
        };
    }

    pub fn toBgr(self: G) BGR {
        return .{
            .b = self.g,
            .g = self.g,
            .r = self.g,
        };
    }

    pub fn toYcbcr(self: G) YCbCr {
        return .{ .y = self.g };
    }

    pub fn toGa(self: G) GA {
        return .{ .g = self.g };
    }

    pub fn toRgba(self: G) RGBA {
        return .{
            .r = self.g,
            .g = self.g,
            .b = self.g,
        };
    }

    pub fn toBgra(self: G) BGRA {
        return .{
            .b = self.g,
            .g = self.g,
            .r = self.g,
        };
    }

    pub fn toYcbcra(self: G) YCbCrA {
        return .{ .y = self.g };
    }

    /// v * 257: exact, 255 -> 65535.
    pub fn toG16(self: G) G16 {
        return .{ .g = misc.from8(self.g) };
    }

    pub fn eql(self: G, other: G) bool {
        return self.g == other.g;
    }
};

test "G" {
    // const gpa = std.testing.allocator;
    // const exp_order: []const []const u8 = &.{"g"};
    // const act_order = comptime std.meta.fieldNames(Order);
    // try misc.checkOrderFieldNames(gpa, exp_order, act_order);

    const data: u8 = 255;
    const gray: G = .init(data);

    const rgb = gray.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .r = 0xFF,
        .g = 0xFF,
        .b = 0xFF,
    }, rgb);

    const bgr = gray.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .r = 0xFF,
        .g = 0xFF,
        .b = 0xFF,
    }, bgr);

    const ycbcr = gray.toYcbcr();
    try std.testing.expectEqualDeep(YCbCr{
        .y = gray.g,
        .cb = 128,
        .cr = 128,
    }, ycbcr);

    const ga = gray.toGa();
    try std.testing.expectEqualDeep(GA{
        .g = gray.g,
        .a = 0xFF,
    }, ga);

    const rgba = gray.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .r = 0xFF,
        .g = 0xFF,
        .b = 0xFF,
        .a = 0xFF,
    }, rgba);

    const bgra = gray.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .b = 0xFF,
        .g = 0xFF,
        .r = 0xFF,
        .a = 0xFF,
    }, bgra);

    const ycbcra = gray.toYcbcra();
    try std.testing.expectEqualDeep(YCbCrA{
        .y = gray.g,
        .cb = 128,
        .cr = 128,
        .a = 0xFF,
    }, ycbcra);

    try std.testing.expect(gray.eql(gray));
}
