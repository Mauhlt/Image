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

pub fn initEmpty(gpa: std.mem.Allocator, len: usize) !RGBS {
    if (len == 0) return error.InvalidDataLen;
    const rgbs = try gpa.alloc(u8, len * field_names.len);
    errdefer gpa.free(rgbs);
    return .{
        .ptr = rgbs.ptr,
        .len = len,
    };
}

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBS {
    if (data.len == 0) return error.InvalidDataLen;
    if (@mod(data.len, field_names.len) != 0) return error.InvalidDataLen;
    const len = data.len / field_names.len;

    const rgbs = try gpa.alloc(u8, data.len);
    errdefer gpa.free(rgbs);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += field_names.len;
    }) {
        const rgb: RGB = .init(data[j..][0..field_names.len], order);
        inline for (field_names, 0..) |field_name, k| {
            rgbs.ptr[i + len * k] = @field(rgb, field_name);
        }
    }

    return .{
        .ptr = rgbs.ptr,
        .len = len,
    };
}

pub fn dupe(self: RGBS, gpa: std.mem.Allocator) !RGBS {
    const rgbs = try gpa.dupe(u8, self.ptr[0 .. self.len * field_names.len]);
    return .{
        .ptr = rgbs.ptr,
        .len = self.len,
    };
}

pub fn deinit(self: RGBS, gpa: std.mem.Allocator) void {
    gpa.free(self.ptr[0 .. self.len * field_names.len]);
}

pub fn replace(self: RGBS, i: usize, rgb: RGB) !void {
    if (i >= self.len) return error.OutOfBounds;
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

pub fn slice(
    self: RGBS,
    gpa: std.mem.Allocator,
    pos: struct {
        start: usize = 0,
        end: usize = self.len,
    },
) ![]RGB {
    if (pos.end < pos.start) return error.InvalidPosition;
    if (pos.end > self.len) return error.OutOfBounds;

    const len = pos.end - pos.start;
    const rgbs = try gpa.dupe(RGB, len);
    for (0..len) |i| rgbs[i] = try self.get(pos.start + i);
    return rgbs;
}

pub fn toGRAYS(self: RGBS, gpa: std.mem.Allocator) !GRAYS {
    const grays: GRAYS = try .initEmpty(gpa, self.len);
    for (0..self.len) |i| try grays.replace(i, (try self.get(i)).toGrayFast16());
    return grays;
}

pub fn toRGBAS(self: RGBS, gpa: std.mem.Allocator) !RGBAS {
    const rgbas: RGBAS = try .initEmpty(gpa, self.len);
    for (0..self.len) |i| rgbas.replace(i, (try self.get(i)).toRGBA());
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
