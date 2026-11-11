const std = @import("std");
const Order = @import("order.zig").Triplets;
const _order = @import("order.zig");
const misc = @import("misc.zig");

const G = @import("g.zig").G;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

pub const RGB = extern struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn init(data: *const [3]u8) RGB {
        return .{
            .r = data[0],
            .g = data[1],
            .b = data[2],
        };
    }

    pub fn initOrder(data: *const [3]u8, order: Order) RGB {
        const idx = order.idx();
        return .{
            .r = data[idx[0]],
            .g = data[idx[1]],
            .b = data[idx[2]],
        };
    }

    pub fn toG(self: RGB) G {
        return .{ .g = misc.lum(self.r, self.g, self.b) };
    }

    pub fn toBgr(self: RGB) BGR {
        return .{
            .b = self.b,
            .g = self.g,
            .r = self.r,
        };
    }

    pub fn toYcbcr(self: RGB) YCbCr {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
        };
    }

    pub fn toGa(self: RGB) GA {
        return .{ .g = misc.lum(self.r, self.g, self.b) };
    }

    pub fn toRgba(self: RGB) RGBA {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }

    pub fn toBgra(self: RGB) BGRA {
        return .{
            .b = self.b,
            .g = self.g,
            .r = self.r,
        };
    }

    pub fn toYcbcra(self: RGB) YCbCrA {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
        };
    }

    pub fn eql(self: RGB, other: RGB) bool {
        return self.r == other.r and //
            self.g == other.g and //
            self.b == other.b;
    }
};

test "RGB" {
    const gpa = std.testing.allocator;
    const exp_field_names: []const []const u8 = &.{
        "rgb",
        "rbg",
        "grb",
        "brg",
        "gbr",
        "bgr",
    };
    const act_field_names = std.meta.fieldNames(Order);
    try _order.checkOrderFieldNames(gpa, exp_field_names, act_field_names);

    const data = [_]u8{ 255, 100, 0 };

    const rgb = RGB.init(&data);
    try std.testing.expectEqualDeep(RGB{
        .r = data[0],
        .g = data[1],
        .b = data[2],
    }, rgb);

    const rgb2 = RGB.initOrder(&data, .bgr);
    try std.testing.expectEqualDeep(RGB{
        .r = data[2],
        .g = data[1],
        .b = data[0],
    }, rgb2);

    const gray = rgb.toG();
    try std.testing.expectEqualDeep(
        G{ .g = 135 },
        gray,
    );

    const bgr = rgb.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .b = rgb.b,
        .g = rgb.g,
        .r = rgb.r,
    }, bgr);

    const ycbcr = rgb.toYcbcr();
    try std.testing.expectEqualDeep(YCbCr{
        .y = gray.g,
        .cb = 52,
        .cr = 214,
    }, ycbcr);

    const ga = rgb.toGa();
    try std.testing.expectEqualDeep(GA{
        .g = gray.g,
        .a = 0xFF,
    }, ga);

    const rgba = rgb.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
    }, rgba);

    const bgra = rgb.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .b = rgb.b,
        .g = rgb.g,
        .r = rgb.r,
        .a = 0xFF,
    }, bgra);

    const ycbcra = rgb.toYcbcra();
    try std.testing.expectEqualDeep(YCbCrA{
        .y = gray.g,
        .cb = 52,
        .cr = 214,
    }, ycbcra);

    try std.testing.expect(rgb.eql(rgb));
}
