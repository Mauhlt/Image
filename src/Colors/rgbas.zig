const std = @import("std");

const POSITION = @import("position.zig");
const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @This();

const Order = RGBA.Order;

// organized r.. g.. b.. a..
ptr: [*]u8, // ptr to start of r
len: usize = 0, // len of 1 field

pub fn initEmpty(gpa: std.mem.Allocator, len: usize) !RGBAS {
    if (len == 0) return error.InvalidDataLen;
    const rgbas = try gpa.alloc(u8, len * @sizeOf(RGBA));
    errdefer gpa.free(rgbas);
    return .{
        .ptr = rgbas.ptr,
        .len = len,
    };
}

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBAS {
    if (data.len == 0) return error.InvalidDataLen;
    if (@mod(data.len, @sizeOf(RGBA)) != 0) return error.InvalidDataLen;
    const len = data.len / @sizeOf(RGBA);

    const rgbas = try gpa.alloc(u8, data.len);
    errdefer gpa.free(rgbas);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += @sizeOf(RGBA);
    }) {
        const rgba: RGBA = .initOrder(data[j..][0..@sizeOf(RGBA)], order);
        inline for (comptime std.meta.fieldNames(RGBA), 0..) |field_name, k| {
            rgbas.ptr[i + len * k] = @field(rgba, field_name);
        }
    }

    return .{
        .ptr = rgbas.ptr,
        .len = len,
    };
}

pub fn dupe(self: RGBAS, gpa: std.mem.Allocator) !RGBAS {
    const rgbas = try gpa.dupe(u8, self.ptr[0 .. self.len * @sizeOf(RGBA)]);
    return .{
        .ptr = rgbas.ptr,
        .len = self.len,
    };
}

pub fn deinit(self: RGBAS, gpa: std.mem.Allocator) void {
    gpa.free(self.ptr[0 .. self.len * @sizeOf(RGBA)]);
}

pub fn replace(self: RGBAS, i: usize, rgba: RGBA) !void {
    if (i >= self.len) return error.OutOfBounds;
    inline for (comptime std.meta.fieldNames(RGBA), 0..) |field_name, k| {
        self.ptr[i + k * self.len] = @field(rgba, field_name);
    }
}

pub fn get(self: RGBAS, i: usize) !RGBA {
    if (i >= self.len) return error.OutOfBounds;
    return .{
        .r = self.ptr[i],
        .g = self.ptr[self.len + i],
        .b = self.ptr[2 * self.len + i],
        .a = self.ptr[3 * self.len + i],
    };
}

pub fn set(self: RGBAS, i: usize, rgba: RGBA) !void {
    if (i >= self.len) return error.OutOfBounds;
    self.ptr[i] = rgba.r;
    self.ptr[self.len + i] = rgba.g;
    self.ptr[self.len * 2 + i] = rgba.b;
    self.ptr[self.len * 3 + i] = rgba.a;
}

pub fn setMany(self: RGBAS, i: usize, len: usize, rgba: RGBA) !void {
    if (i + len > self.len) return error.OutOfBounds;
    @memset(self.ptr[i..][0..len], rgba.r);
    @memset(self.ptr[self.len + i ..][0..len], rgba.g);
    @memset(self.ptr[2 * self.len + i ..][0..len], rgba.b);
    @memset(self.ptr[3 * self.len + i ..][0..len], rgba.a);
}

pub fn slice(
    self: RGBAS,
    allo: std.mem.Allocator,
    pos: POSITION,
) ![]RGBA {
    if (pos.start == 0 and pos.end == 0) {
        const rgbas = try allo.alloc(RGBA, self.len);
        errdefer allo.free(rgbas);
        for (0..self.len) |i| rgbas[i] = try self.get(i);
        return rgbas;
    }

    if (pos.end <= pos.start) return error.InvalidPosition;
    if (pos.end > self.len) return error.OutOfBounds;

    const len = pos.end - pos.start;
    const rgbas = try allo.alloc(RGBA, len);
    errdefer allo.free(rgbas);
    for (0..len) |i| rgbas[i] = try self.get(pos.start + i);
    return rgbas;
}

pub fn toGRAYS(self: RGBAS, gpa: std.mem.Allocator) !GRAYS {
    const grays: GRAYS = try .initEmpty(gpa, self.len);
    for (0..self.len) |i| {
        const gray = (try self.get(i)).toGrayFast16();
        try grays.replace(i, gray);
    }
    return grays;
}

pub fn toRGBS(self: RGBAS, gpa: std.mem.Allocator) !RGBS {
    const rgbs: RGBS = try .initEmpty(gpa, self.len);
    for (0..self.len) |i| {
        const rgb = (try self.get(i)).toRGB();
        try rgbs.replace(i, rgb);
    }
    return rgbs;
}

test "RGBAS" {
    const allo = std.testing.allocator;
    const data = [_]u8{ 255, 100, 0, 10 };

    const base: RGBAS = try .init(allo, &data, .rgba);
    defer base.deinit(allo);

    { // init
        try std.testing.expectEqual(data.len / @sizeOf(RGBA), base.len);
        const rgba = try base.get(0);
        const ergba: RGBA = .{ .r = data[0], .g = data[1], .b = data[2], .a = data[3] };
        try std.testing.expectEqualDeep(ergba, rgba);
    }

    { // flip order
        const rgbas: RGBAS = try .init(allo, &data, .abgr);
        defer rgbas.deinit(allo);
        try std.testing.expectEqual(data.len / @sizeOf(RGBA), rgbas.len);
        const rgba = try rgbas.get(0);
        const ergba: RGBA = .{ .r = data[3], .g = data[2], .b = data[1], .a = data[0] };
        try std.testing.expectEqualDeep(ergba, rgba);
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
        const rgbs = try base.toRGBS(allo);
        defer rgbs.deinit(allo);
        const rgb = try rgbs.get(0);
        const ergb: RGB = .{ .r = data[0], .g = data[1], .b = data[2] };
        try std.testing.expectEqualDeep(ergb, rgb);
    }
}
