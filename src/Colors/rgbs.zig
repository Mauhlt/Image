const std = @import("std");

const POSITION = @import("position.zig");
const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @import("rgbas.zig");
const RGBS = @This();

const Order = RGB.Order;

ptr: [*]u8,
len: usize, // # of pixels

pub fn initEmpty(gpa: std.mem.Allocator, len: usize) !RGBS {
    if (len == 0) return error.InvalidDataLen;
    const rgbs = try gpa.alloc(u8, len * @sizeOf(RGB));
    errdefer gpa.free(rgbs);
    return .{
        .ptr = rgbs.ptr,
        .len = len,
    };
}

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBS {
    if (data.len == 0) return error.InvalidDataLen;
    if (@mod(data.len, @sizeOf(RGB)) != 0) return error.InvalidDataLen;
    const len = data.len / @sizeOf(RGB);

    const rgbs = try gpa.alloc(u8, data.len);
    errdefer gpa.free(rgbs);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += @sizeOf(RGB);
    }) {
        const rgb: RGB = .initOrder(data[j..][0..@sizeOf(RGB)], order);
        inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
            rgbs.ptr[i + len * k] = @field(rgb, field_name);
        }
    }
    return .{
        .ptr = rgbs.ptr,
        .len = len,
    };
}

pub fn dupe(self: RGBS, gpa: std.mem.Allocator) !RGBS {
    const rgbs = try gpa.dupe(u8, self.ptr[0 .. self.len * @sizeOf(RGB)]);
    return .{
        .ptr = rgbs.ptr,
        .len = self.len,
    };
}

pub fn deinit(self: RGBS, gpa: std.mem.Allocator) void {
    gpa.free(self.ptr[0 .. self.len * @sizeOf(RGB)]);
}

pub fn replace(self: RGBS, i: usize, rgb: RGB) !void {
    if (i >= self.len) return error.OutOfBounds;
    inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
        self.ptr[i + k * self.len] = @field(rgb, field_name);
    }
}

pub fn get(self: RGBS, i: usize) !RGB {
    if (i > self.len) return error.OutOfBounds;
    var rgb: RGB = undefined;
    inline for (comptime std.meta.fieldNames(RGB), 0..) |field_name, k| {
        @field(rgb, field_name) = self.ptr[i + k * self.len];
    }
    return rgb;
}

pub fn set(self: RGBS, i: usize, rgb: RGB) !void {
    if (i >= self.len) return error.OutOfBounds;
    self.ptr[i] = rgb.r;
    self.ptr[self.len + i] = rgb.g;
    self.ptr[self.len * 2 + i] = rgb.b;
}

pub fn setMany(self: RGBS, i: usize, len: usize, rgb: RGB) !void {
    if (i + len >= self.len) return error.OutOfBounds;
    @memset(self.ptr[i..][0..len], rgb.r);
    @memset(self.ptr[self.len + i ..][0..len], rgb.g);
    @memset(self.ptr[2 * self.len + i ..][0..len], rgb.b);
}

pub fn slice(
    self: RGBS,
    gpa: std.mem.Allocator,
    pos: POSITION,
) ![]RGB {
    if (pos.start == 0 and pos.end == 0) {
        const rgbs = try gpa.alloc(RGB, self.len);
        errdefer gpa.free(rgbs);
        for (0..self.len) |i| rgbs[i] = try self.get(i);
        return rgbs;
    }

    if (pos.end < pos.start) return error.InvalidPosition;
    if (pos.end > self.len) return error.OutOfBounds;

    const len = pos.end - pos.start;
    const rgbs = try gpa.alloc(RGB, len);
    errdefer gpa.free(rgbs);
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
    for (0..self.len) |i| try rgbas.replace(i, (try self.get(i)).toRGBA());
    return rgbas;
}

test "RGBS" {
    const allo = std.testing.allocator;
    const data = [_]u8{ 255, 100, 0 };

    const base: RGBS = try .init(allo, &data, .rgb);
    defer base.deinit(allo);

    { // init
        try std.testing.expectEqual(data.len / @sizeOf(RGB), base.len);
        const rgb = try base.get(0);
        const ergb: RGB = .{ .r = data[0], .g = data[1], .b = data[2] };
        try std.testing.expectEqualDeep(ergb, rgb);
    }

    { // flip order
        const rgbs: RGBS = try .init(allo, &data, .bgr);
        defer rgbs.deinit(allo);
        try std.testing.expectEqual(data.len / @sizeOf(RGB), rgbs.len);
        const rgb = try rgbs.get(0);
        const ergb: RGB = .{ .r = data[2], .g = data[1], .b = data[0] };
        try std.testing.expectEqualDeep(ergb, rgb);
    }

    { // convert + sliced
        const grays = try base.toGRAYS(allo);
        defer grays.deinit(allo);
        try std.testing.expectEqual(base.len, grays.len);
        const sliced = try grays.slice(allo, .{});
        defer allo.free(sliced);
        const gray = sliced[0];
        const egray: GRAY = .{ .g = 134 };
        try std.testing.expectEqualDeep(egray, gray);
    }

    {
        const rgbas = try base.toRGBAS(allo);
        defer rgbas.deinit(allo);
        const rgba = try rgbas.get(0);
        const ergba: RGBA = .{ .r = data[0], .g = data[1], .b = data[2], .a = 0xFF };
        try std.testing.expectEqualDeep(ergba, rgba);
    }
}
