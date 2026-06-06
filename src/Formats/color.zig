const std = @import("std");
pub const GRAY = u8;

pub const RGB = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

pub const RGBA = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0xFF,
};

const DataOrder = enum(u64) {
    gray,
    rgb,
    rbg,
    grb,
    gbr,
    brg,
    bgr,
    rgba,
    rbga,
    grba,
    gbra,
    brga,
    bgra,
    _,
};

const PixelOrder = enum(u64) {
    gray,
    rgb,
    rgba,
};

pub const Pixels = union(PixelOrder) {
    gray: []GRAY,
    rgb: []RGB,
    rgba: []RGBA,

    pub fn init(
        gpa: std.mem.Allocator,
        data: []const u8,
        data_order: DataOrder,
        pixel_order: PixelOrder,
    ) !@This() {
        const j_step: usize = 1;
        var i_step: usize = undefined;
        switch (data_order) {
            .gray => i_step = 1,
            .rgb, .rbg, .grb, .gbr, .brg, .bgr => i_step = 3,
            .rgba, .rbga, .grba, .gbra, .brga, .bgra => i_step = 4,
            _ => return error.Unsupported,
        }
        if (@mod(data.len, i_step) != 0) //
            return error.InvalidDimensions;
        const new_data = switch (data_order) {
            .gray => unreachable,
            .rgb, .rgba, .rbg, .rbga, .grb, .gbr, .brg, .bgr, .grba, .gbra, .brga, .bgra => //
            try gpa.alloc(RGB, data.len / i_step),
            _ => unreachable,
        };
        errdefer gpa.free(new_data);
        var r_step: usize = undefined;
        var g_step: usize = undefined;
        var b_step: usize = undefined;
        var a_step: usize = undefined;
        switch (data_order) {
            .gray => unreachable,
            .rgb, .rgba, .rbg, .rbga, .grb, .gbr, .brg, .bgr, .grba, .gbra, .brga, .bgra => |tag| {
                r_step = std.mem.indexOfScalar(u8, @tagName(tag), 'r').?;
                g_step = std.mem.indexOfScalar(u8, @tagName(tag), 'g').?;
                b_step = std.mem.indexOfScalar(u8, @tagName(tag), 'b').?;
                a_step = std.mem.indexOfScalar(u8, @tagName(tag), 'a') orelse 4;
            },
            _ => unreachable,
        }
        var i: usize = 0;
        var j: usize = 0;
        switch (pixel_order) {
            .gray => {},
            .rgb => {
                while (i < data.len) : ({
                    i += i_step;
                    j += j_step;
                }) {
                    new_data[j] = .{
                        .r = data[i + r_step],
                        .g = data[i + g_step],
                        .b = data[i + b_step],
                    };
                }
            },
            .rgba => {
                while (i < data.len) : ({
                    i += i_step;
                    j += j_step;
                }) {
                    new_data[j] = .{
                        .r = data[i + r_step],
                        .g = data[i + g_step],
                        .b = data[i + b_step],
                        .a = data[i + a_step],
                    };
                }
            },
        }
        return new_data;
    }

    pub fn deinit(self: Pixels, gpa: std.mem.Allocator) void {
        switch (self) {
            .gray => |gray| gpa.free(gray),
            .rgb => |rgb| gpa.free(rgb),
            .rgba => |rgba| gpa.free(rgba),
        }
    }
};

test "toPixel" {
    const gpa = std.testing.allocator;
    const TestRGB = struct { data_order: DataOrder, rgb: RGB };

    const rgb_data: []const u8 = &.{ 255, 100, 1 };
    const expected_rgbs = [_]TestRGB{
        .{ .data_order = .rgb, .rgb = .{ .r = 255, .g = 100, .b = 1 } },
        .{ .data_order = .rbg, .rgb = .{ .r = 255, .g = 1, .b = 100 } },
        .{ .data_order = .grb, .rgb = .{ .r = 100, .g = 255, .b = 1 } },
        .{ .data_order = .gbr, .rgb = .{ .r = 1, .g = 255, .b = 100 } },
        .{ .data_order = .brg, .rgb = .{ .r = 100, .g = 1, .b = 255 } },
        .{ .data_order = .bgr, .rgb = .{ .r = 1, .g = 100, .b = 255 } },
    };
    for (expected_rgbs) |expected_rgb| {
        const rgb = try toRGB(gpa, rgb_data, expected_rgb.data_order);
        defer gpa.free(rgb);
        try std.testing.expectEqualDeep(expected_rgb.rgb, rgb[0]);
    }

    const rgba_data: []const u8 = &.{ 255, 100, 1, 255 };
    const expected_rgbas = [_]TestRGB{
        .{ .data_order = .rgba, .rgb = .{ .r = 255, .g = 100, .b = 1 } },
        .{ .data_order = .rbga, .rgb = .{ .r = 255, .g = 1, .b = 100 } },
        .{ .data_order = .grba, .rgb = .{ .r = 100, .g = 255, .b = 1 } },
        .{ .data_order = .gbra, .rgb = .{ .r = 1, .g = 255, .b = 100 } },
        .{ .data_order = .brga, .rgb = .{ .r = 100, .g = 1, .b = 255 } },
        .{ .data_order = .bgra, .rgb = .{ .r = 1, .g = 100, .b = 255 } },
    };
    for (expected_rgbas) |expected_rgba| {
        const rgb = try toRGB(gpa, rgba_data, expected_rgba.data_order);
        defer gpa.free(rgb);
        try std.testing.expectEqualDeep(expected_rgba.rgb, rgb[0]);
    }
}

fn grayFromRGB(rgb: RGB) GRAY {
    return @as(u8, @intFromFloat(0.299 * @as(f32, @floatFromInt(rgb.r)) + 0.587 * @as(f32, @floatFromInt(rgb.g)) + 0.114 * @as(f32, @floatFromInt(rgb.b))));
}
