const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig").RGB;
const RGBA = @import("rgba.zig").RGBA;
const RGBAS = @import("rgbas.zig");

const RGBS = @This();

slice: []RGB,

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: RGB.Order) !RGBS {
    const n_fields = comptime std.meta.fieldNames(RGB).len;
    if (@mod(data.len, n_fields) != 0) return error.InvalidDataLen;
    const len = data.len / n_fields;

    var rgbs = try gpa.alloc(RGB, len);
    errdefer gpa.free(rgbs);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += n_fields;
    }) {
        rgbs[i] = .initOrder(data[j..][0..n_fields], order);
    }

    return .{ .slice = rgbs };
}

pub fn deinit(self: *const RGBS, gpa: std.mem.Allocator) void {
    gpa.free(self.slice);
}

pub fn toGRAYS(rgbs: RGBS, gpa: std.mem.Allocator) !GRAYS {
    const grays = try gpa.alloc(GRAY, rgbs.slice.len);
    for (0..rgbs.slice.len) |i| grays[i] = rgbs.slice[i].toGrayFast16();
    return .{ .slice = grays };
}

pub fn toRGBAS(rgbs: RGBS, gpa: std.mem.Allocator) !RGBAS {
    var rgbas = try gpa.alloc(RGBA, rgbs.slice.len);
    for (0..rgbs.slice.len) |i| rgbas[i] = rgbs.slice[i].toRGBA();
    return .{ .slice = rgbas };
}

test "RGBS" {
    const allo = std.testing.allocator;
    const data = [_]u8{ 255, 100, 0 };

    const rgbs: RGBS = try .init(allo, &data, .rgb);
    defer rgbs.deinit(allo);

    const rgbs2: RGBS = try .init(allo, &data, .bgr);
    defer rgbs2.deinit(allo);

    const grays = try rgbs.toGRAYS(allo);
    defer grays.deinit(allo);

    const rgbas = try rgbs.toRGBAS(allo);
    defer rgbas.deinit(allo);
}
