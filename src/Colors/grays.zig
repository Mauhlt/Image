const std = @import("std");

const POSITION = @import("position.zig");
const GRAY = @import("gray.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @import("rgbas.zig");
const GRAYS = @This();

const Order = GRAY.Order;
const field_names = std.meta.fieldNames(GRAY);

// organized g..
ptr: [*]u8, // ptr to start of g
len: usize = 0,

pub fn initEmpty(allo: std.mem.Allocator, len: usize) !GRAYS {
    if (len == 0) return error.InvalidDataLen;
    const grays = try allo.alloc(u8, len * field_names.len);
    return .{
        .ptr = grays.ptr,
        .len = grays.len,
    };
}

pub fn init(allo: std.mem.Allocator, data: []const u8) !GRAYS {
    if (data.len == 0) return error.InvalidDataLen;
    const grays = try allo.dupe(u8, data);
    return .{
        .ptr = grays.ptr,
        .len = grays.len,
    };
}

pub fn dupe(self: GRAYS, allo: std.mem.Allocator) !GRAYS {
    const grays = allo.dupe(u8, self.ptr[0..self.len]);
    return .{
        .ptr = grays.ptr,
        .len = self.len,
    };
}

pub fn deinit(self: GRAYS, allo: std.mem.Allocator) void {
    allo.free(self.ptr[0..self.len]);
}

pub fn replace(self: GRAYS, i: usize, gray: GRAY) !void {
    if (i >= self.len) return error.OutOfBounds;
    self.ptr[i] = gray.g;
}

pub fn get(self: GRAYS, i: usize) !GRAY {
    if (i >= self.len) return error.OutOfBounds;
    return .{ .g = self.ptr[i] };
}

pub fn slice(
    self: GRAYS,
    allo: std.mem.Allocator,
    pos: POSITION,
) ![]GRAY {
    if (pos.start == 0 and pos.end == 0) {
        const grays = try allo.alloc(GRAY, self.len);
        errdefer allo.free(grays);
        for (0..self.len) |i| grays[i] = try self.get(i);
        return grays;
    }

    if (pos.end <= pos.start) return error.InvalidPosition;
    if (pos.end > self.len) return error.OutOfBounds;

    const len = pos.end - pos.start;
    const grays = try allo.alloc(GRAY, len);
    errdefer allo.free(grays);
    for (0..len) |i| grays[i] = try self.get(pos.start + i);
    return grays;
}

pub fn toRGBS(self: GRAYS, allo: std.mem.Allocator) !RGBS {
    const rgbs: RGBS = try .initEmpty(allo, self.len);
    for (0..self.len) |i| {
        const rgb = (try self.get(i)).toRGB();
        rgbs.replace(i, rgb);
    }
    return rgbs;
}

pub fn toRGBAS(self: GRAYS, allo: std.mem.Allocator) !RGBAS {
    const rgbas: RGBAS = try .initEmpty(allo, self.len);
    for (0..self.len) |i| {
        const rgba = (try self.get(i)).toRGBA();
        rgbas.replace(i, rgba);
    }
    return rgbas;
}

test "GRAYS" {
    // data
    const data = [_]u8{ 255, 100, 0, 10, 50, 75 };
    // const expected_rgbs = [_]RGB{
    //     .{ .r = 255, .g = 255, .b = 255 },
    //     .{ .r = 100, .g = 100, .b = 100 },
    //     .{ .r = 0, .g = 0, .b = 0 },
    //     .{ .r = 10, .g = 10, .b = 10 },
    //     .{ .r = 50, .g = 50, .b = 50 },
    //     .{ .r = 75, .g = 75, .b = 75 },
    // };
    // const expected_rgbas = [_]RGBA{
    //     .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    //     .{ .r = 100, .g = 100, .b = 100, .a = 255 },
    //     .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    //     .{ .r = 10, .g = 10, .b = 10, .a = 255 },
    //     .{ .r = 50, .g = 50, .b = 50, .a = 255 },
    //     .{ .r = 75, .g = 75, .b = 75, .a = 255 },
    // };

    const allo = std.testing.allocator;

    {
        const empties: GRAYS = try .initEmpty(allo, data.len);
        defer empties.deinit(allo);
        try std.testing.expectEqual(empties.len, data.len);

        const sliced = try empties.slice(allo, .{});
        defer allo.free(sliced);
        for (sliced) |curr_slice| {
            try std.testing.expectEqual(curr_slice.g, 0);
        }
    }

    // {
    //     const grays: GRAYS = try .init(allo, &data);
    //     defer grays.deinit(allo);
    //     const sliced = try grays.slice(allo, .{});
    //     defer allo.free(sliced);
    // }

    // pub fn init(gpa: std.mem.Allocator, data: []const u8) !GRAYS {
    // pub fn dupe(self: GRAYS, gpa: std.mem.Allocator) !GRAYS {
    // pub fn deinit(self: GRAYS, gpa: std.mem.Allocator) void {
    // pub fn replace(self: GRAYS, i: usize, gray: GRAY) !void {
    // pub fn get(self: GRAYS, i: usize) !GRAY {
    // pub fn slice(
    //     self: GRAYS,
    //     gpa: std.mem.Allocator,
    //     pos: struct {
    //         start: usize = 0,
    //         end: usize = self.len,
    //     }
    // )
    // pub fn toRGBS(self: GRAYS, gpa: std.mem.Allocator) !RGBS {
    // pub fn toRGBAS(self: GRAYS, gpa: std.mem.Allocator) !RGBAS {

    // {
    //     const grays2 = try grays.slice(allo, .{});
    //     defer allo.free(grays2);
    //     for (0..data.len, slice) |datum, datum2| {
    //         try std.testing.expectEqual(datum, datum2.g);
    //     }
    // }
    //
    // {
    //     const rgbs = try grays.toRGBS(allo);
    //     defer rgbs.deinit(allo);
    //     const len = rgbs.len;
    //     for (0..len) |i| {
    //         const rgb = rgbs.get(i);
    //         const e_rgb = expected_rgbs[i];
    //         try std.testing.expectEqualDeep(rgb, e_rgb);
    //     }
    // }
    //
    // {
    //     const rgbas = try grays.toRGBAS(allo);
    //     defer rgbas.deinit(allo);
    //     const len = rgbas.len;
    //     for (0..len) |i| {
    //         const rgba = rgbas.get(i);
    //         const e_rgb = expected_rgbs[i];
    //         try std.testing.expectEqualDeep(
    //             rgba,
    //             RGBA{ .r = e_rgb.r, .g = e_rgb.g, .b = e_rgb.b },
    //         );
    //     }
    // }
}
