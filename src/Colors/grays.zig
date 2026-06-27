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
    const grays = try allo.dupe(u8, self.ptr[0..self.len]);
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
    // slow conversions - faster = use simd
    const rgbs: RGBS = try .initEmpty(allo, self.len);
    for (0..3) |i| {
        @memcpy(rgbs.ptr[i * rgbs.len .. (i + 1) * rgbs.len], self.ptr[0..self.len]);
    }
    return rgbs;
}

pub fn toRGBAS(self: GRAYS, allo: std.mem.Allocator) !RGBAS {
    const rgbas: RGBAS = try .initEmpty(allo, self.len);
    for (0..3) |i| {
        @memcpy(rgbas.ptr[i * rgbas.len .. (i + 1) * rgbas.len], self.ptr[0..self.len]);
    }
    @memset(rgbas.ptr[3 * rgbas.len .. 4 * rgbas.len], 255); // default to opaque
    return rgbas;
}

test "GRAYS" {
    // data
    const data = [_]u8{ 255, 100, 0, 10, 50, 75 };
    const expected_rgbs = [_]RGB{
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 100, .g = 100, .b = 100 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 10, .g = 10, .b = 10 },
        .{ .r = 50, .g = 50, .b = 50 },
        .{ .r = 75, .g = 75, .b = 75 },
    };
    const expected_rgbas = [_]RGBA{
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 100, .g = 100, .b = 100, .a = 255 },
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 10, .g = 10, .b = 10, .a = 255 },
        .{ .r = 50, .g = 50, .b = 50, .a = 255 },
        .{ .r = 75, .g = 75, .b = 75, .a = 255 },
    };

    const allo = std.testing.allocator;

    { // Init Empty
        const empties: GRAYS = try .initEmpty(allo, data.len);
        defer empties.deinit(allo);
        try std.testing.expectEqual(empties.len, data.len);

        const sliced = try empties.slice(allo, .{});
        defer allo.free(sliced);
        try std.testing.expectEqual(sliced.len, data.len);
    }

    { // Init + Slice
        const grays: GRAYS = try .init(allo, &data);
        defer grays.deinit(allo);
        const sliced = try grays.slice(allo, .{});
        defer allo.free(sliced);
        try std.testing.expectEqual(grays.len, sliced.len);
        for (0..sliced.len) |i| {
            try std.testing.expectEqual(sliced.ptr[i].g, data[i]);
        }
    }

    { // Dupe
        const grays: GRAYS = try .init(allo, &data);
        defer grays.deinit(allo);
        const grays2 = try grays.dupe(allo);
        defer grays2.deinit(allo);
        try std.testing.expectEqual(grays.len, grays2.len);
        for (0..grays.len) |i| {
            try std.testing.expectEqual(grays.ptr[i], grays2.ptr[i]);
        }
    }

    { // Replace
        const grays: GRAYS = try .init(allo, &data);
        defer grays.deinit(allo);
        try grays.replace(4, .{ .g = 255 });
        for (0..grays.len) |i| {
            if (i != 4) {
                try std.testing.expectEqual(grays.ptr[i], data[i]);
            } else {
                try std.testing.expectEqual(grays.ptr[i], 255);
            }
        }
        try std.testing.expectEqual((try grays.get(4)).g, 255);
    }

    { // Slice
        const grays: GRAYS = try .init(allo, &data);
        defer grays.deinit(allo);
        const sliced = try grays.slice(allo, .{});
        defer allo.free(sliced);
        for (0..grays.len) |i| {
            try std.testing.expectEqual(try grays.get(i), sliced[i]);
        }
    }

    { // RGB
        const grays: GRAYS = try .init(allo, &data);
        defer grays.deinit(allo);

        const rgbs: RGBS = try grays.toRGBS(allo);
        defer rgbs.deinit(allo);

        const ergbs: RGBS = try .init(allo, @ptrCast(&expected_rgbs), .rgb);
        defer ergbs.deinit(allo);

        try std.testing.expectEqual(rgbs.len, ergbs.len);
        for (0..rgbs.len) |i| {
            const rgb = try rgbs.get(i);
            const ergb = try ergbs.get(i);
            try std.testing.expectEqualDeep(ergb, rgb);
        }
    }

    { // RGBA
        const grays: GRAYS = try .init(allo, &data);
        defer grays.deinit(allo);

        const rgbas: RGBAS = try grays.toRGBAS(allo);
        defer rgbas.deinit(allo);

        const ergbas: RGBAS = try .init(allo, @ptrCast(@alignCast(&expected_rgbas)), .rgba);
        defer ergbas.deinit(allo);

        try std.testing.expectEqual(rgbas.len, ergbas.len);
        for (0..rgbas.len) |i| {
            const rgba = try rgbas.get(i);
            const ergba = try ergbas.get(i);
            try std.testing.expectEqualDeep(ergba, rgba);
        }
    }
}
