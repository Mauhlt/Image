const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig");
const Order = RGBA.Order;

const RGBAS = @This();

slice: []RGBA,

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBAS {
    const n_fields = comptime std.meta.fieldNames(RGBA).len;
    if (@mod(data.len, n_fields) != 0) return error.InvalidDataLen;
    const len = data.len / n_fields;

    var rgbas = try gpa.alloc(RGBA, len);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += n_fields;
    }) {
        rgbas[i] = .initOrder(data[j..][0..n_fields], order);
    }

    return .{ .slice = rgbas };
}

pub fn deinit(self: *const RGBAS, gpa: std.mem.Allocator) void {
    gpa.free(self.slice);
}

pub fn toGRAYS(rgbas: RGBAS, gpa: std.mem.Allocator) !GRAYS {
    var grays = try gpa.alloc(GRAY, rgbas.slice.len);
    for (0..rgbas.slice.len) |i| grays[i] = rgbas.slice[i].toGrayFast16();
    return .{ .slice = grays };
}

pub fn toRGBS(rgbas: RGBAS, gpa: std.mem.Allocator) !RGBS {
    var rgbs = try gpa.alloc(RGB, rgbas.slice.len);
    for (0..rgbas.slice.len) |i| rgbs[i] = rgbas.slice[i].toRGB();
    return .{ .slice = rgbs };
}

test "RGBAS" {
    const allo = std.testing.allocator;
    const data = [_]u8{ 255, 100, 0, 10 };

    const rgbas: RGBAS = try .init(allo, &data, .rgba);
    defer rgbas.deinit(allo);
    try std.testing.expectEqualDeep(
        rgbas.slice[0],
        RGBA{ .r = data[0], .g = data[1], .b = data[2], .a = data[3] },
    );

    const rgbas2: RGBAS = try .init(allo, &data, .abgr);
    defer rgbas2.deinit(allo);
    try std.testing.expectEqualDeep(
        rgbas2.slice[0],
        RGBA{ .r = data[3], .g = data[2], .b = data[1], .a = data[0] },
    );

    const grays = try rgbas.toGRAYS(allo);
    defer grays.deinit(allo);
    try std.testing.expectEqualDeep(grays.slice[0], GRAY{ .g = 134 });

    const rgbs = try rgbas.toRGBS(allo);
    defer rgbs.deinit(allo);
    try std.testing.expectEqualDeep(
        rgbs.slice[0],
        RGB{ .r = data[0], .g = data[1], .b = data[2] },
    );
}
