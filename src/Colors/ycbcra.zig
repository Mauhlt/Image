const std = @import("std");
const Order = @import("order.zig").Quadruplets;
const misc = @import("misc.zig");

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;

pub const YCbCrA = extern struct {
    y: u8,
    cb: u8 = 128,
    cr: u8 = 128,
    a: u8 = 0xFF,

    pub fn init(data: *const [3]u8) YCbCrA {
        return .{
            .y = data[0],
            .cb = data[1],
            .cr = data[2],
        };
    }

    pub fn initOrder(data: *const [3]u8, order: Order) YCbCrA {
        const ind = order.idx();
        return .{
            .y = data[ind[0]],
            .cb = data[ind[1]],
            .cr = data[ind[2]],
        };
    }

    pub fn toG(self: YCbCrA) G {
        return .{ .g = self.y };
    }

    pub fn toRgb(self: YCbCrA) RGB {
        return .{
            .r = misc.red(self.y, self.cr),
            .g = misc.green(self.y, self.cb, self.cr),
            .b = misc.blue(self.y, self.cb),
        };
    }

    pub fn toBgr(self: YCbCrA) BGR {
        return .{
            .b = misc.blue(self.y, self.cb),
            .g = misc.green(self.y, self.cb, self.cr),
            .r = misc.red(self.y, self.cr),
        };
    }

    pub fn toYcbcr(self: YCbCrA) YCbCr {
        return .{
            .y = self.y,
            .cb = self.cb,
            .cr = self.cr,
        };
    }

    pub fn toGa(self: YCbCrA) GA {
        return .{
            .g = self.y,
            .a = self.a,
        };
    }

    pub fn toRgba(self: YCbCrA) RGBA {
        return .{
            .r = misc.red(self.y, self.cr),
            .g = misc.green(self.y, self.cb, self.cr),
            .b = misc.blue(self.y, self.cb),
            .a = self.a,
        };
    }

    pub fn toBgra(self: YCbCrA) BGRA {
        return .{
            .b = misc.blue(self.y, self.cb),
            .g = misc.green(self.y, self.cb, self.cr),
            .r = misc.red(self.y, self.cr),
            .a = self.a,
        };
    }

    pub fn eql(self: YCbCrA, other: YCbCrA) bool {
        return self.y == other.y and //
            self.cb == other.cb and //
            self.cr == other.cr and //
            self.a == other.a;
    }
};

test "YCbCrA" {
    const data = [_]u8{ 0, 100, 255 };

    const ycbcra: YCbCrA = .init(&data);
    try std.testing.expectEqualDeep(YCbCrA{
        .y = data[0],
        .cb = data[1],
        .cr = data[2],
    }, ycbcra);

    const gray = ycbcra.toG();
    try std.testing.expectEqualDeep(
        G{ .g = 0 },
        gray,
    );

    const rgb = ycbcra.toRgb();
    const rgb_exp = RGB{
        .r = misc.red(ycbcra.y, ycbcra.cr),
        .g = misc.green(ycbcra.y, ycbcra.cb, ycbcra.cr),
        .b = misc.blue(ycbcra.y, ycbcra.cb),
    };
    try std.testing.expectEqualDeep(rgb_exp, rgb);

    const bgr = ycbcra.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .b = rgb_exp.b,
        .g = rgb_exp.g,
        .r = rgb_exp.r,
    }, bgr);

    const ga = ycbcra.toGa();
    try std.testing.expectEqualDeep(GA{
        .g = 0,
        .a = 0xFF,
    }, ga);

    const rgba = ycbcra.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
        .a = 0xFF,
    }, rgba);

    const bgra = ycbcra.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .r = bgr.r,
        .g = bgr.g,
        .b = bgr.b,
        .a = 0xFF,
    }, bgra);

    try std.testing.expect(ycbcra.eql(ycbcra));
}
