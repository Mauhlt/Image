const std = @import("std");
const GRAY = @import("gray.zig");
const RGBA = @import("rgba.zig");

const RGB = @This();

r: u8,
g: u8,
b: u8,

// stores position as u6 (every 2 bytes = position)
pub const Order = enum(u8) {
    rgb = 0b0000_0110,
    rbg = 0b0000_1001,
    grb = 0b0001_0010,
    brg = 0b0001_1000,
    gbr = 0b0010_0001,
    bgr = 0b0010_0100,

    pub fn toIndices(order: Order) RGB {
        const value: u8 = @intFromEnum(order);
        return .{
            .r = (value & 0b0011_0000) >> 4,
            .g = (value & 0b0000_1100) >> 2,
            .b = (value & 0b0000_0011),
        };
    }
};

pub fn init(data: *const [3]u8) RGB {
    return .{
        .r = data[0],
        .g = data[1],
        .b = data[2],
    };
}

pub fn initOrder(data: *const [3]u8, order: Order) RGB {
    const idx = order.toIndices();
    return .{
        .r = data[idx.r],
        .g = data[idx.g],
        .b = data[idx.b],
    };
}

pub fn toGRAY(rgb: RGB) GRAY {
    // slow
    return .{
        .g = @intFromFloat( //
        0.2989 * @as(f32, @floatFromInt(rgb.r)) +
            0.587 * @as(f32, @floatFromInt(rgb.g)) +
            0.1140 * @as(f32, @floatFromInt(rgb.b)) //
        ),
    };
}

pub fn toGrayFast8(rgb: RGB) GRAY {
    // using 8-bit coeffs
    const r: u32 = rgb.r;
    const g: u32 = rgb.g;
    const b: u32 = rgb.b;
    return .{ .g = @truncate((77 *% r +% 150 *% g +% 29 *% b) >> 8) };
}

pub fn toGrayFast16(rgb: RGB) GRAY {
    // using 16-bit coeffs for slightly more accuracy at no extra cost
    const r: u32 = rgb.r;
    const g: u32 = rgb.g;
    const b: u32 = rgb.b;
    return .{ .g = @truncate((19595 *% r +% 38470 *% g +% 7471 *% b) >> 16) };
}

pub fn toRGBA(rgb: RGB) RGBA {
    return .{
        .r = rgb.r,
        .g = rgb.g,
        .b = rgb.b,
    };
}

test "RGB" {
    // check that field orders are correct
    const order_fields = comptime std.meta.fields(Order);
    const field_names = comptime std.meta.fieldNames(RGB);
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

    const data = [_]u8{ 255, 100, 0 };

    const rgb: RGB = .init(&data);
    try std.testing.expectEqualDeep(rgb, RGB{ .r = data[0], .g = data[1], .b = data[2] });

    const rgb2: RGB = .initOrder(&data, .bgr);
    try std.testing.expectEqualDeep(rgb2, RGB{ .r = data[2], .g = data[1], .b = data[0] });

    const gray = rgb.toGRAY();
    try std.testing.expectEqualDeep(gray, GRAY{ .g = 134 });

    const gray8 = rgb.toGrayFast8();
    try std.testing.expectEqualDeep(gray8, GRAY{ .g = 135 });

    const gray16 = rgb.toGrayFast16();
    try std.testing.expectEqualDeep(gray16, GRAY{ .g = 134 }); // use this one

    const rgba = rgb.toRGBA();
    try std.testing.expectEqualDeep(rgba, RGBA{ .r = rgb.r, .g = rgb.g, .b = rgb.b });
}
