const std = @import("std");
const _order = @import("order.zig");
const Order = @import("order.zig").Doublets;
const misc = @import("misc.zig");
const G16 = @import("g16.zig").G16;

const G = @import("g.zig").G;
const RGB = @import("rgb.zig").RGB;
const BGR = @import("bgr.zig").BGR;
const YCbCr = @import("ycbcr.zig").YCbCr;

const RGBA = @import("rgba.zig").RGBA;
const BGRA = @import("bgra.zig").BGRA;
const YCbCrA = @import("ycbcra.zig").YCbCrA;

pub const GA = extern struct {
    g: u8,
    a: u8 = 0xFF,

    pub fn init(data: *const [2]u8) GA {
        return .{
            .g = data[0],
            .a = data[1],
        };
    }

    pub fn initOrder(data: *const [2]u8, order: Order) GA {
        const idx = order.idx();
        return .{
            .g = data[idx[0]],
            .a = data[idx[1]],
        };
    }

    /// The 8-bit gray (`toG`) widened by v * 257.
    pub fn toG16(self: GA) G16 {
        return .{ .g = misc.from8(self.toG().g) };
    }

    pub fn toG(self: GA) G {
        return .{
            .g = self.g,
        };
    }

    pub fn toRgb(self: GA) RGB {
        return .{
            .r = self.g,
            .g = self.g,
            .b = self.g,
        };
    }

    pub fn toBgr(self: GA) BGR {
        return .{
            .b = self.g,
            .g = self.g,
            .r = self.g,
        };
    }

    pub fn toYcbcr(self: GA) YCbCr {
        return .{
            .y = self.g,
        };
    }

    pub fn toRgba(self: GA) RGBA {
        return .{
            .r = self.g,
            .g = self.g,
            .b = self.g,
            .a = self.a,
        };
    }

    pub fn toBgra(self: GA) BGRA {
        return .{
            .b = self.g,
            .g = self.g,
            .r = self.g,
            .a = self.a,
        };
    }

    pub fn toYcbcra(self: GA) YCbCrA {
        return .{
            .y = self.g,
            .a = self.a,
        };
    }

    pub fn eql(self: GA, other: GA) bool {
        return self.g == other.g and //
            self.a == other.a;
    }
};

test "GA" {
    const gpa = std.testing.allocator;
    // check order
    const exp_field_names: []const []const u8 = &.{ "ga", "ag" };
    const act_field_names = std.meta.fieldNames(Order);
    try _order.checkOrderFieldNames(gpa, exp_field_names, act_field_names);

    const data = [_]u8{ 10, 255 };

    const ga: GA = .init(&data);
    try std.testing.expectEqualDeep(GA{
        .g = 10,
        .a = 255,
    }, ga);

    const ga2: GA = .initOrder(&data, .ag);
    try std.testing.expectEqualDeep(GA{
        .g = 255,
        .a = 10,
    }, ga2);

    const g: G = ga.toG();
    try std.testing.expectEqualDeep(
        G{ .g = 10 },
        g,
    );

    const rgb = ga.toRgb();
    try std.testing.expectEqualDeep(RGB{
        .r = ga.g,
        .g = ga.g,
        .b = ga.g,
    }, rgb);

    const bgr = ga.toBgr();
    try std.testing.expectEqualDeep(BGR{
        .b = ga.g,
        .g = ga.g,
        .r = ga.g,
    }, bgr);

    const ycbcr = ga.toYcbcr();
    try std.testing.expectEqualDeep(YCbCr{
        .y = ga.g,
    }, ycbcr);

    const rgba = ga.toRgba();
    try std.testing.expectEqualDeep(RGBA{
        .r = ga.g,
        .g = ga.g,
        .b = ga.g,
        .a = ga.a,
    }, rgba);

    const bgra = ga.toBgra();
    try std.testing.expectEqualDeep(BGRA{
        .b = ga.g,
        .g = ga.g,
        .r = ga.g,
        .a = ga.a,
    }, bgra);

    const ycbcra = ga.toYcbcra();
    try std.testing.expectEqualDeep(YCbCrA{
        .y = ga.g,
    }, ycbcra);

    try std.testing.expect(ga.eql(ga));
}
