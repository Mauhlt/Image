const std = @import("std");
const Order = @import("order.zig").Quadruplets;
const misc = @import("misc.zig");

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

pub const BGRA = extern struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8 = 0xFF,

    pub fn init(data: *const [4]u8) BGRA {
        return .{
            .b = data[0],
            .g = data[1],
            .r = data[2],
            .a = data[3],
        };
    }

    pub fn initOrder(data: *const [4]u8, order: Order) BGRA {
        const idx = order.idx();
        return .{
            .b = data[idx[2]],
            .g = data[idx[1]],
            .r = data[idx[0]],
            .a = data[idx[3]],
        };
    }

    pub fn toG(self: BGRA) G {
        return .{
            .g = misc.lum(self.r, self.g, self.b),
        };
    }

    pub fn toRgb(self: BGRA) RGB {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }

    pub fn toBgr(self: BGRA) BGR {
        return .{
            .b = self.b,
            .g = self.g,
            .r = self.r,
        };
    }

    pub fn toYcbcr(self: BGRA) YCbCr {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
        };
    }

    pub fn toGa(self: BGRA) GA {
        return .{
            .g = misc.lum(self.r, self.g, self.b),
            .a = self.a,
        };
    }

    pub fn toRgba(self: BGRA) RGBA {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
            .a = self.a,
        };
    }

    pub fn toYcbcra(self: BGRA) YCbCrA {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
            .a = self.a,
        };
    }

    pub fn eql(self: BGRA, other: BGRA) bool {
        return self.b == other.b and //
            self.g == other.g and //
            self.r == other.r and //
            self.a == other.a;
    }
};

test "BGRA" {
    const data = [_]u8{ 0, 100, 255, 255 };

    const bgra: BGRA = .init(&data);
    try std.testing.expect( //
        bgra.r == data[2] and //
            bgra.g == data[1] and //
            bgra.b == data[0] and //
            bgra.a == data[3] //
    );

    const bgra2: BGRA = .initOrder(&data, .rgba);
    try std.testing.expectEqualDeep(
        BGRA{
            .b = data[2],
            .g = data[1],
            .r = data[0],
            .a = data[3],
        },
        bgra2,
    );

    const gray = bgra.toG();
    try std.testing.expectEqualDeep(
        G{ .g = 135 },
        gray,
    );

    const rgb = bgra.toRgb();
    try std.testing.expectEqualDeep(
        RGB{
            .r = data[2],
            .g = data[1],
            .b = data[0],
        },
        rgb,
    );

    const bgr = bgra.toBgr();
    try std.testing.expectEqualDeep(
        BGR{
            .b = data[0],
            .g = data[1],
            .r = data[2],
        },
        bgr,
    );

    const ycbcr = bgra.toYcbcr();
    try std.testing.expectEqualDeep(
        YCbCr{
            .y = 135,
            .cb = 52,
            .cr = 214,
        },
        ycbcr,
    );

    const ga = bgra.toGa();
    try std.testing.expectEqualDeep(
        GA{
            .g = gray.g,
            .a = 0xFF,
        },
        ga,
    );

    const rgba = bgra.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .r = bgra.r,
        .g = bgra.g,
        .b = bgra.b,
        .a = bgra.a,
    }, rgba);

    const ycbcra = bgra.toYcbcra();
    try std.testing.expectEqualDeep(
        YCbCrA{
            .y = 135,
            .cb = 52,
            .cr = 214,
            .a = 0xFF,
        },
        ycbcra,
    );

    try std.testing.expect(bgra.eql(bgra));
}
