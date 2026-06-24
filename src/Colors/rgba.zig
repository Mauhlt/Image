const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBAS = @import("rgba.zig");

const RGBA = @This();

r: u8 = 0,
g: u8 = 0,
b: u8 = 0,
a: u8 = 255,

pub const Order = enum(u8) {
    rgba = 0b0001_1011,
    rgab = 0b0001_1110,
    rbga = 0b0010_0111,
    rbag = 0b0011_0110,
    ragb = 0b0010_1101,
    rabg = 0b0011_1001,

    grba = 0b0100_1011,
    grab = 0b0100_1110,
    brga = 0b0110_0011,
    brag = 0b0111_0010,
    argb = 0b0110_1100,
    arbg = 0b0111_1000,

    gbra = 0b1000_0111,
    garb = 0b1000_1101,
    bgra = 0b1001_0011,
    barg = 0b1011_0001,
    agrb = 0b1001_1100,
    abrg = 0b1011_0100,

    gbar = 0b1100_0110,
    gabr = 0b1100_1001,
    bgar = 0b1101_0010,
    bagr = 0b1110_0001,
    agbr = 0b1101_1000,
    abgr = 0b1110_0100,

    pub fn toIndices(order: Order) RGBA {
        const value: u8 = @intFromEnum(order);
        return .{
            .r = (value & 0b1100_0000) >> 6,
            .g = (value & 0b0011_0000) >> 4,
            .b = (value & 0b0000_1100) >> 2,
            .a = (value & 0b0000_0011),
        };
    }
};

pub fn init(data: *const [4]u8) RGBA {
    return .{
        .r = data[0],
        .g = data[1],
        .b = data[2],
        .a = data[3],
    };
}

pub fn initOrder(data: *const [4]u8, order: Order) RGBA {
    const idx = order.toIndices();
    return .{
        .r = data[idx.r],
        .g = data[idx.g],
        .b = data[idx.b],
        .a = data[idx.a],
    };
}

pub fn toInt(rgba: RGBA) u32 {
    return rgba.r << 24 | rgba.g << 16 | rgba.b << 8 | rgba.a;
}

pub fn toGRAY(rgba: RGBA) GRAY {
    return .{
        .g = @intFromFloat( //
        0.2989 * @as(f32, @floatFromInt(rgba.r)) + //
            0.587 * @as(f32, @floatFromInt(rgba.g)) + //
            0.1140 * @as(f32, @floatFromInt(rgba.b)) //
        )
    };
}

pub fn toGrayFast8(rgba: RGBA) GRAY {
    // using 8-bit coeffs
    const r: u32 = rgba.r;
    const g: u32 = rgba.g;
    const b: u32 = rgba.b;
    return .{ .g = @truncate((77 *% r +% 150 *% g +% 29 *% b) >> 8) };
}

pub fn toGrayFast16(rgba: RGBA) GRAY {
    const r: u32 = rgba.r;
    const g: u32 = rgba.g;
    const b: u32 = rgba.b;
    return .{ .g = @truncate((19595 *% r +% 38470 *% g +% 7471 *% b) >> 16) };
}

pub fn toRGB(rgba: RGBA) RGB {
    return .{
        .r = rgba.r,
        .g = rgba.g,
        .b = rgba.b,
    };
}

pub fn eql(self: RGBA, other: RGBA) bool {
    return self.r == other.r and //
        self.g == other.g and //
        self.b == other.b and //
        self.a == other.a;
}

test "RGBA" {
    // check that field orders are correct
    const order_fields = comptime std.meta.fields(RGBA.Order);
    const field_names = comptime std.meta.fieldNames(RGBA);
    inline for (order_fields) |order_field| {
        const name = order_field.name;
        const value = order_field.value;
        var indices = [_]u8{0} ** field_names.len;
        for (0..field_names.len) |i| {
            indices[i] = @truncate(std.mem.indexOfScalar(u8, name, field_names[i][0]).?);
        }
        var new_value: u8 = 0;
        var i: usize = 0;
        var j: usize = 2 * field_names.len - 2;
        while (i < field_names.len) : ({
            i += 1;
            j -%= 2;
        }) {
            new_value |= indices[i] << @truncate(j);
        }
        try std.testing.expectEqual(value, new_value);
    }

    const data = [_]u8{ 255, 100, 0, 10 };

    const rgba: RGBA = .init(&data);
    try std.testing.expectEqualDeep(
        rgba,
        RGBA{ .r = data[0], .g = data[1], .b = data[2], .a = data[3] },
    );

    const rgba2: RGBA = .initOrder(&data, .abgr);
    try std.testing.expectEqualDeep(
        rgba2,
        RGBA{ .r = data[3], .g = data[2], .b = data[1], .a = data[0] },
    );

    const gray = rgba.toGRAY();
    try std.testing.expectEqualDeep(gray, GRAY{ .g = 134 });

    const gray8 = rgba.toGrayFast8();
    try std.testing.expectEqualDeep(gray8, GRAY{ .g = 135 });

    // preferred
    const gray16 = rgba.toGrayFast16();
    try std.testing.expectEqualDeep(gray16, GRAY{ .g = 134 });

    const rgb = rgba.toRGB();
    try std.testing.expectEqualDeep(rgb, RGB{ .r = rgb.r, .g = rgb.g, .b = rgb.b });
}
