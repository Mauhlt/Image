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

inline fn isValidDataLen(data: []const u8, step: usize) bool {
    return @mod(data.len, step) == 0;
}

inline fn rgbaFromDataOrder(data_order: DataOrder) !RGBA {
    switch (data_order) {
        .rgba,
        .rbga,
        .grba,
        .gbra,
        .brga,
        .bgra,
        .rgb,
        .rbg,
        .grb,
        .gbr,
        .brg,
        .bgr,
        => |tag| {
            const tagname = @tagName(tag);
            return .{
                .r = @truncate(std.mem.indexOfScalar(u8, tagname, 'r').?),
                .g = @truncate(std.mem.indexOfScalar(u8, tagname, 'g').?),
                .b = @truncate(std.mem.indexOfScalar(u8, tagname, 'b').?),
                .a = @truncate(std.mem.indexOfScalar(u8, tagname, 'a') orelse 3),
            };
        },
        else => return error.InvalidDataOrder,
        _ => return error.UnsupportedDataOrder,
    }
}

fn computeStride(data_order: DataOrder) !usize {
    return switch (data_order) {
        .gray => 1,
        .rgb, .rbg, .grb, .gbr, .brg, .bgr => 3,
        .rgba, .rbga, .grba, .gbra, .brga, .bgra => 4,
        _ => return error.UnsupportedDataOrder,
    };
}

inline fn grayFromRGB(rgb: RGB) GRAY {
    return @intFromFloat(0.299 * @as(f32, @floatFromInt(rgb.r)) + //
        0.587 * @as(f32, @floatFromInt(rgb.g)) + //
        0.114 * @as(f32, @floatFromInt(rgb.b)));
}

inline fn rgbFromGray(gray: GRAY) RGB {
    return .{
        .r = @intFromFloat(0.299 * @as(f32, @floatFromInt(gray))),
        .g = @intFromFloat(0.587 * @as(f32, @floatFromInt(gray))),
        .b = @intFromFloat(0.114 * @as(f32, @floatFromInt(gray))),
    };
}

inline fn rgbaFromGray(gray: GRAY) RGBA {
    return .{
        .r = @intFromFloat(0.299 * @as(f32, @floatFromInt(gray))),
        .g = @intFromFloat(0.587 * @as(f32, @floatFromInt(gray))),
        .b = @intFromFloat(0.114 * @as(f32, @floatFromInt(gray))),
        .a = 255,
    };
}

fn toGRAY(
    gpa: std.mem.Allocator,
    data: []const u8,
    data_order: DataOrder,
) ![]GRAY {
    var n_pixels: usize = undefined;
    if (data_order == .gray) return gpa.dupe(GRAY, @as([]const GRAY, data));
    const stride = try computeStride(data_order);
    if (!isValidDataLen(data, stride)) return error.InvalidDataLen;
    n_pixels = data.len / stride;
    var new_data = try gpa.alloc(GRAY, n_pixels);
    errdefer gpa.free(new_data);
    const tag_order = try rgbaFromDataOrder(data_order);
    var i: usize = 0;
    switch (data_order) {
        .gray => unreachable,
        else => {
            while (i < new_data.len) : (i += 1) {
                new_data[i] = grayFromRGB(.{
                    .r = data[i * stride + tag_order.r],
                    .g = data[i * stride + tag_order.g],
                    .b = data[i * stride + tag_order.b],
                });
            }
        },
        _ => return error.UnsupportedDataOrder,
    }
    return new_data;
}

fn toRGB(
    gpa: std.mem.Allocator,
    data: []const u8,
    data_order: DataOrder,
) ![]RGB {
    var n_pixels: usize = undefined;
    const stride = try computeStride(data_order);
    if (!isValidDataLen(data, stride)) return error.InvalidDataLen;
    n_pixels = data.len / stride;
    var new_data = try gpa.alloc(RGB, n_pixels);
    errdefer gpa.free(new_data);
    const tag_order = try rgbaFromDataOrder(data_order);
    var i: usize = 0;
    switch (data_order) {
        .gray => {
            while (i < new_data.len) : (i += 1) {
                new_data[i] = rgbFromGray(data[i]);
            }
        },
        .rgb, .rbg, .grb, .gbr, .brg, .bgr, .rgba, .rbga, .grba, .gbra, .brga, .bgra => {
            while (i < new_data.len) : (i += 1) {
                new_data[i] = .{
                    .r = data[i * stride + tag_order.r],
                    .g = data[i * stride + tag_order.g],
                    .b = data[i * stride + tag_order.b],
                };
            }
        },
        _ => return error.UnsupportedDataOrder,
    }
    return new_data;
}

fn toRGBA(
    gpa: std.mem.Allocator,
    data: []const u8,
    data_order: DataOrder,
) ![]RGBA {
    var n_pixels: usize = undefined;
    const stride = try computeStride(data_order);
    if (!isValidDataLen(data, stride)) return error.InvalidDataLen;
    n_pixels = data.len / stride;
    var new_data = try gpa.alloc(RGBA, n_pixels);
    errdefer gpa.free(new_data);
    const tag_order = try rgbaFromDataOrder(data_order);
    var i: usize = 0;
    switch (data_order) {
        .gray => {
            while (i < new_data.len) : (i += 1) {
                new_data[i] = rgbaFromGray(data[i]);
            }
        },
        .rgb, .rbg, .grb, .gbr, .brg, .bgr => {
            while (i < new_data.len) : (i += 1) {
                new_data[i] = .{
                    .r = data[i * stride + tag_order.r],
                    .g = data[i * stride + tag_order.g],
                    .b = data[i * stride + tag_order.b],
                    .a = 255,
                };
            }
        },
        .rgba, .rbga, .grba, .gbra, .brga, .bgra => {
            while (i < new_data.len) : (i += 1) {
                new_data[i] = .{
                    .r = data[i * stride + tag_order.r],
                    .g = data[i * stride + tag_order.g],
                    .b = data[i * stride + tag_order.b],
                    .a = data[i * stride + tag_order.a],
                };
            }
        },
        _ => return error.UnsupportedDataOrder,
    }
    return new_data;
}

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
        return switch (pixel_order) {
            .gray => .{ .gray = try toGRAY(gpa, data, data_order) },
            .rgb => .{ .rgb = try toRGB(gpa, data, data_order) },
            .rgba => .{ .rgba = try toRGBA(gpa, data, data_order) },
        };
    }

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            .gray => |grays| gpa.free(grays),
            .rgb => |rgbs| gpa.free(rgbs),
            .rgba => |rgbas| gpa.free(rgbas),
        }
    }
};

test "toPixel" {
    const gpa = std.testing.allocator;
    const TestRGB = struct { data_order: DataOrder, rgb: RGB };
    const TestRGBA = struct { data_order: DataOrder, rgba: RGBA };

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
        const rgb: Pixels = try .init(gpa, rgb_data, expected_rgb.data_order, .rgb);
        defer rgb.deinit(gpa);
        try std.testing.expectEqualDeep(expected_rgb.rgb, rgb.rgb[0]);
    }

    const rgba_data: []const u8 = &.{ 255, 100, 1, 255 };
    const expected_rgbas = [_]TestRGBA{
        .{ .data_order = .rgba, .rgba = .{ .r = 255, .g = 100, .b = 1 } },
        .{ .data_order = .rbga, .rgba = .{ .r = 255, .g = 1, .b = 100 } },
        .{ .data_order = .grba, .rgba = .{ .r = 100, .g = 255, .b = 1 } },
        .{ .data_order = .gbra, .rgba = .{ .r = 1, .g = 255, .b = 100 } },
        .{ .data_order = .brga, .rgba = .{ .r = 100, .g = 1, .b = 255 } },
        .{ .data_order = .bgra, .rgba = .{ .r = 1, .g = 100, .b = 255 } },
    };
    for (expected_rgbas) |expected_rgba| {
        const rgba: Pixels = try .init(gpa, rgba_data, expected_rgba.data_order, .rgba);
        defer rgba.deinit(gpa);
        try std.testing.expectEqualDeep(expected_rgba.rgba, rgba.rgba[0]);
    }
}
