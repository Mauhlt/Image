const std = @import("std");
const Order = @import("order.zig").Triplets;
const misc = @import("misc.zig");

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

pub const BGR = extern struct {
    b: u8,
    g: u8,
    r: u8,

    pub fn init(data: *const [3]u8) BGR {
        return .{
            .b = data[0],
            .g = data[1],
            .r = data[2],
        };
    }

    pub fn initOrder(data: *const [3]u8, order: Order) BGR {
        const idx = order.idx();
        return .{
            .b = data[idx[2]],
            .g = data[idx[1]],
            .r = data[idx[0]],
        };
    }

    pub fn toG(self: BGR) G {
        return .{
            .g = misc.lum(self.r, self.g, self.b),
        };
    }

    pub fn toRgb(self: BGR) RGB {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }

    pub fn toYcbcr(self: BGR) YCbCr {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
        };
    }

    pub fn toGa(self: BGR) GA {
        return .{
            .g = misc.lum(self.r, self.g, self.b),
        };
    }

    pub fn toRgba(self: BGR) RGBA {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }

    pub fn toBgra(self: BGR) BGRA {
        return .{
            .b = self.b,
            .g = self.g,
            .r = self.r,
        };
    }

    pub fn toYcbcra(self: BGR) YCbCrA {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
        };
    }

    pub fn eql(self: BGR, other: BGR) bool {
        return self.b == other.b and //
            self.g == other.g and //
            self.r == other.r;
    }
};

test "BGR" {
    const data = [_]u8{ 0, 100, 255 };

    const bgr = BGR.init(&data);
    try std.testing.expectEqualDeep(BGR{
        .r = data[2],
        .g = data[1],
        .b = data[0],
    }, bgr);

    const bgr2 = BGR.initOrder(&data, .rgb);
    try std.testing.expectEqualDeep(BGR{
        .b = data[2],
        .g = data[1],
        .r = data[0],
    }, bgr2);

    const gray = bgr.toG();
    try std.testing.expectEqualDeep(
        G{ .g = 135 },
        gray,
    );

    const rgb = bgr.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .r = bgr.r,
        .g = bgr.g,
        .b = bgr.b,
    }, rgb);

    const ycbcr = bgr.toYcbcr();
    try std.testing.expectEqualDeep(YCbCr{
        .y = gray.g,
        .cr = 214,
        .cb = 52,
    }, ycbcr);

    const ga = bgr.toGa();
    try std.testing.expectEqualDeep(GA{
        .g = gray.g,
        .a = 0xFF,
    }, ga);

    const rgba = bgr.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .r = bgr.r,
        .g = bgr.g,
        .b = bgr.b,
    }, rgba);

    const bgra = bgr.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .r = bgr.r,
        .g = bgr.g,
        .b = bgr.b,
        .a = 0xFF,
    }, bgra);

    const ycbcra = bgr.toYcbcra();
    try std.testing.expectEqualDeep(YCbCrA{
        .y = gray.g,
        .cb = 52,
        .cr = 214,
    }, ycbcra);

    try std.testing.expect(bgr.eql(bgr));
}
