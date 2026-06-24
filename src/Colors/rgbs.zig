const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig").RGB;
const RGBA = @import("rgba.zig").RGBA;
const RGBAS = @import("rgbas.zig");
const RGBS = @This();

const Order = RGB.Order;

data: std.MultiArrayList(RGB),

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBS {
    const n_fields = comptime std.meta.fieldNames(RGB).len;
    if (@mod(data.len, n_fields) != 0) return error.InvalidDataLen;
    const len = data.len / n_fields;

    var rgbs: std.MultiArrayList(RGB) = try .initCapacity(gpa, len);
    errdefer gpa.free(rgbs);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += n_fields;
    }) {
        rgbs.appendAssumeCapacity(.initOrder(data[j..][0..n_fields], order));
    }

    return .{ .data = rgbs };
}

pub fn deinit(self: *const RGBS, gpa: std.mem.Allocator) void {
    self.data.deinit(gpa);
}

pub fn toGRAYS(rgbs: RGBS, gpa: std.mem.Allocator) !GRAYS {
    const len = rgbs.data.len;
    const grays = try gpa.alloc(GRAY, len);
    for (0..len) |i| grays[i] = rgbs.data.get(i).toGrayFast16();
    return .{ .data = grays };
}

pub fn toRGBAS(rgbs: RGBS, gpa: std.mem.Allocator) !RGBAS {
    const len = rgbs.data.len;
    var rgbas: std.MultiArrayList(RGBA) = try .initCapacity(gpa, len);
    for (0..len) |i| rgbas.appendAssumeCapacity(rgbs.data.get(i).toRGBA());
    return .{ .data = rgbas };
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
