const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @import("rgbas.zig");
const RGBS = @This();

const Order = RGB.Order;
const field_names = std.meta.fieldNames(RGB);

ptr: [*]u8,
len: usize,

pub fn allocEmpty(gpa: std.mem.Allocator, len: usize) !RGBS {
    if (len == 0) return error.InvalidDataLen;
    if (@mod(len, field_names.len) != 0) return error.InvalidDataLen;
    const len = n / field_names.len;

    const rgbs = try gpa.alloc(u8, n);
    return .{
        .ptr = rgbs.ptr,
        .len = len,
    };
}

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBS {
    const n_fields = field_names.len;
    if (@mod(data.len, n_fields) != 0) return error.InvalidDataLen;
    const len = data.len / n_fields;

    const rgbs = try gpa.alloc(u8, data.len);
    errdefer gpa.deinit(rgbs);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += n_fields;
    }) {
        const rgb: RGB = .init(data[j..][0..n_fields], order);
        inline for (field_names, 0..) |field_name, k| {
            rgbs[i + len * k] = @field(rgb, field_name);
        }
    }

    return .{
        .ptr = rgbs.ptr,
        .len = len,
    };
}

pub fn deinit(self: *const RGBS, gpa: std.mem.Allocator) void {
    gpa.free(self.r[0 .. self.len * field_names.len]);
}

pub fn replace(self: RGBS, i: usize, rgb: RGB) !void {
    if (i > self.len) return error.OutOfBounds;
    inline for (field_names, 0..) |field_name, k| {
        self.ptr[i + k * self.len] = @field(rgb, field_name);
    }
}

pub fn get(self: RGBS, i: usize) !RGB {
    if (i > self.len) return error.OutOfBounds;
    var rgb: RGB = undefined;
    inline for (field_names, 0..) |field_name, k| {
        @field(rgb, field_name) = self.ptr[i + k * self.len];
    }
    return rgb;
}

pub fn toGRAYS(self: RGBS, gpa: std.mem.Allocator) !GRAYS {
    const len = self.len;
    const grays: GRAYS = try .allocEmpty(gpa, len);
    for (0..len) |i| grays.replace(i, self.get(i).toGrayFast16());
    return grays;
}

pub fn toRGBAS(rgbs: RGBS, gpa: std.mem.Allocator) !RGBAS {
    const len = rgbs.data.len;
    var rgbas: std.MultiArrayList(RGBA) = try .initCapacity(gpa, len);
    for (0..len) |i| rgbas.appendAssumeCapacity(rgbs.data.get(i).toRGBA());
    return rgbas;
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
