const std = @import("std");
const Order = @import("order.zig").Triplets;
const misc = @import("misc.zig");

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;

const GA = @import("ga.zig").GA;
const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

const shift: i16 = 14;
const round: i16 = 1 << (shift - 1);

pub const YCbCr = extern struct {
    y: u8,
    cb: u8 = 128,
    cr: u8 = 128,

    pub fn init(data: *const [3]u8) YCbCr {
        return .{
            .y = data[0],
            .cb = data[1],
            .cr = data[2],
        };
    }

    pub fn initOrder(data: *const [3]u8, order: Order) YCbCr {
        const ind = order.idx();
        return .{
            .y = data[ind[0]],
            .cb = data[ind[1]],
            .cr = data[ind[2]],
        };
    }

    pub fn toG(self: YCbCr) G {
        return .{ .g = self.y };
    }

    pub fn toRgb(self: YCbCr) RGB {
        return .{
            .r = misc.red(self.y, self.cr),
            .g = misc.green(self.y, self.cb, self.cr),
            .b = misc.blue(self.y, self.cb),
        };
    }

    pub fn toBgr(self: YCbCr) BGR {
        return .{
            .b = misc.blue(self.y, self.cb),
            .g = misc.green(self.y, self.cb, self.cr),
            .r = misc.red(self.y, self.cr),
        };
    }

    pub fn toGa(self: YCbCr) GA {
        return .{ .g = self.y };
    }

    pub fn toRgba(self: YCbCr) RGBA {
        return .{
            .r = misc.red(self.y, self.cr),
            .g = misc.green(self.y, self.cb, self.cr),
            .b = misc.blue(self.y, self.cb),
        };
    }

    pub fn toBgra(self: YCbCr) BGRA {
        return .{
            .b = misc.blue(self.y, self.cb),
            .g = misc.green(self.y, self.cb, self.cr),
            .r = misc.red(self.y, self.cr),
        };
    }

    pub fn toYcbcra(self: YCbCr) YCbCrA {
        return .{
            .y = self.y,
            .cb = self.cb,
            .cr = self.cr,
        };
    }

    pub fn eql(self: YCbCr, other: YCbCr) bool {
        return self.y == other.y and //
            self.cb == other.cb and //
            self.cr == other.cr;
    }
};

test "YCbCr" {
    const data = [_]u8{ 0, 100, 255 };

    const ycbcr: YCbCr = .init(&data);
    try std.testing.expectEqualDeep(YCbCr{
        .y = data[0],
        .cb = data[1],
        .cr = data[2],
    }, ycbcr);

    const gray = ycbcr.toG();
    try std.testing.expectEqualDeep(
        G{ .g = 0 },
        gray,
    );

    const rgb = ycbcr.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .r = misc.red(ycbcr.y, ycbcr.cr),
        .g = misc.green(ycbcr.y, ycbcr.cb, ycbcr.cr),
        .b = misc.blue(ycbcr.y, ycbcr.cb),
    }, rgb);

    const bgr = ycbcr.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .b = rgb.b,
        .g = rgb.g,
        .r = rgb.r,
    }, bgr);

    const ga = ycbcr.toGa();
    try std.testing.expectEqualDeep(GA{
        .g = 0,
        .a = 0xFF,
    }, ga);

    const rgba = ycbcr.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .r = misc.red(ycbcr.y, ycbcr.cr),
        .g = misc.green(ycbcr.y, ycbcr.cb, ycbcr.cr),
        .b = misc.blue(ycbcr.y, ycbcr.cb),
        .a = 0xFF,
    }, rgba);

    const bgra = ycbcr.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .r = bgr.r,
        .g = bgr.g,
        .b = bgr.b,
        .a = 0xFF,
    }, bgra);

    const ycbcra = ycbcr.toYcbcra();
    try std.testing.expectEqualDeep(YCbCrA{
        .y = 0,
        .cr = 255,
        .cb = 100,
    }, ycbcra);

    try std.testing.expect(ycbcr.eql(ycbcr));
}
