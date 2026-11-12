const std = @import("std");
const Order = @import("order.zig").Quadruplets;
const _order = @import("order.zig");
const misc = @import("misc.zig");
const G16 = @import("g16.zig").G16;

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const GA = @import("ga.zig").GA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

pub const RGBA = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 0xFF,

    pub fn init(data: *const [4]u8) RGBA {
        return .{
            .r = data[0],
            .g = data[1],
            .b = data[2],
            .a = data[3],
        };
    }

    pub fn initOrder(data: *const [4]u8, order: Order) RGBA {
        const idx = order.idx();
        return .{
            .r = data[idx[0]],
            .g = data[idx[1]],
            .b = data[idx[2]],
            .a = data[idx[3]],
        };
    }

    /// The 8-bit gray (`toG`) widened by v * 257.
    pub fn toG16(self: RGBA) G16 {
        return .{ .g = misc.from8(self.toG().g) };
    }

    pub fn toG(self: RGBA) G {
        return .{ .g = misc.lum(self.r, self.g, self.b) };
    }

    pub fn toRgb(self: RGBA) RGB {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }

    pub fn toBgr(self: RGBA) BGR {
        return .{
            .b = self.b,
            .g = self.g,
            .r = self.r,
        };
    }

    pub fn toYcbcr(self: RGBA) YCbCr {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
        };
    }

    pub fn toGa(self: RGBA) GA {
        return .{
            .g = misc.lum(self.r, self.g, self.b),
            .a = self.a,
        };
    }

    pub fn toBgra(self: RGBA) BGRA {
        return .{
            .b = self.b,
            .g = self.g,
            .r = self.r,
            .a = self.a,
        };
    }

    pub fn toYcbcra(self: RGBA) YCbCrA {
        return .{
            .y = misc.lum(self.r, self.g, self.b),
            .cb = misc.blueChroma(self.r, self.g, self.b),
            .cr = misc.redChroma(self.r, self.g, self.b),
            .a = self.a,
        };
    }

    pub fn eql(self: RGBA, other: RGBA) bool {
        return self.r == other.r and //
            self.g == other.g and //
            self.b == other.b and //
            self.a == other.a;
    }

    // pub fn toRgb565(rgb: RGB) u16 {
    //     return (@as(u16, rgb.r >> 3) | (@as(u16, rgb.g >> 2) << 5) | (rgb.b >> 3));
    // }
    //
    // pub fn fromRgb565(c: u16) @This() {
    //     const r5: u8 = @truncate(c >> 11);
    //     const g6: u8 = @truncate((c >> 5) & 0x3F);
    //     const b5: u8 = @truncate(c & 0x1F);
    //     return .{
    //         .red = r5,
    //         .green = g6,
    //         .blue = b5,
    //     };
    // }
};

test "RGBA" {
    const gpa = std.testing.allocator;
    // check that field orders are correct
    const exp_field_names: []const []const u8 = &.{
        "rgba", "rgab", "rbga", "rbag", "ragb", "rabg", //
        "grba", "grab", "gbra", "garb", "gbar", "gabr", //
        "brga", "brag", "bgra", "barg", "bgar", "bagr", //
        "argb", "arbg", "agrb", "abrg", "agbr", "abgr", //
    };
    const act_field_names = std.meta.fieldNames(Order);
    try _order.checkOrderFieldNames(gpa, exp_field_names, act_field_names);

    const data = [_]u8{ 255, 100, 0, 255 };

    const rgba: RGBA = .init(&data);
    try std.testing.expect( //
        rgba.r == data[0] and //
            rgba.g == data[1] and //
            rgba.b == data[2] and //
            rgba.a == data[3]);

    const rgba2: RGBA = .initOrder(&data, .bgra);
    try std.testing.expectEqualDeep(RGBA{
        .r = data[2],
        .g = data[1],
        .b = data[0],
    }, rgba2);

    const gray = rgba.toG();
    try std.testing.expectEqual(135, gray.g);

    const rgb = rgba.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .r = data[0],
        .g = data[1],
        .b = data[2],
    }, rgb);

    const bgr = rgba.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .r = data[0],
        .g = data[1],
        .b = data[2],
    }, bgr);

    const ga = rgba.toGa();
    try std.testing.expectEqualDeep(GA{
        .g = gray.g,
        .a = 0xFF,
    }, ga);

    const bgra = rgba.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .b = rgba.b,
        .g = rgba.g,
        .r = rgba.r,
        .a = rgba.a,
    }, bgra);

    try std.testing.expect(rgba.eql(rgba));
}
