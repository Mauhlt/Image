const std = @import("std");

const GRAY = @import("gray.zig");
const RGB = @import("rgb.zig").RGB;
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig").RGBA;
const RGBAS = @import("rgbas.zig");
const GRAYS = @This();

ptr: [*]u8,
len: usize,

pub fn allocEmpty(gpa: std.mem.Allocator, len: usize) !GRAYS {
    if (len == 0) return error.InvalidDataLen;
    const grays = try gpa.alloc(u8, len);
    return .{
        .ptr = grays.ptr,
        .len = grays.len,
    };
}

pub fn init(gpa: std.mem.Allocator, data: []const u8) !GRAYS {
    const grays = try gpa.dupe(u8, data);
    return .{
        .ptr = grays.ptr,
        .len = grays.len,
    };
}

pub fn dupe(self: GRAYS, gpa: std.mem.Allocator) !GRAYS {
    const grays = gpa.dupe(u8, self.ptr[0..self.len]);
    return .{
        .ptr = grays.ptr,
        .len = grays.len,
    };
}

pub fn deinit(self: GRAYS, gpa: std.mem.Allocator) void {
    gpa.free(self.ptr[0..self.len]);
}

pub fn replace(self: GRAYS, i: usize, gray: GRAY) !void {
    if (i > self.len) return error.OutOfBounds;
    self.ptr[i] = gray;
}

pub fn get(self: GRAYS, i: usize) !GRAY {
    if (i > self.len) return error.OutOfBounds;
    return self.ptr[i];
}

pub fn slice(
    self: GRAYS,
    gpa: std.mem.Allocator,
    pos: struct {
        start: usize = 0,
        end: usize = self.len,
    },
) ![]GRAY {
    if (pos.end < pos.start) return error.InvalidStartEnd;
    if ((pos.end - pos.start) > self.len) return error.OutOfBounds;
    const len = pos.end - pos.start;

    const grays = try gpa.dupe(GRAY, len);
    for (0..len) |i| {
        grays[i] = self.get(pos.start + i) catch unreachable;
    }

    return grays;
}

pub fn toRGBS(self: GRAYS, gpa: std.mem.Allocator) !RGBS {
    const rgbs: RGBS = try .allocEmpty(gpa, self.len);
    for (0..self.len) |i| {
        const rgb = (try self.get(i)).toRGB();
        rgbs.replace(i, rgb);
    }
    return rgbs;
}

pub fn toRGBAS(self: GRAYS, gpa: std.mem.Allocator) !RGBAS {
    const rgbas: RGBAS = try .allocEmpty(gpa, self.len);
    for (0..self.len) |i| {
        const rgba = (try self.get(i)).toRGBA();
        rgbas.replace(i, rgba);
    }
    return rgbas;
}

test "GRAYS" {
    const data = [_]u8{ 255, 100, 0, 10, 50, 75 };
    const expected_rgbs = [_]RGB{
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 100, .g = 100, .b = 100 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 10, .g = 10, .b = 10 },
        .{ .r = 50, .g = 50, .b = 50 },
        .{ .r = 75, .g = 75, .b = 75 },
    };

    const allo = std.testing.allocator;

    const grays = try init(allo, &data);
    defer grays.deinit(allo);

    {
        const rgbs = try grays.toRGBS(allo);
        defer rgbs.deinit(allo);
        const len = rgbs.len;
        for (0..len) |i| {
            const rgb = rgbs.get(i);
            const e_rgb = expected_rgbs[i];
            try std.testing.expectEqualDeep(rgb, e_rgb);
        }
    }

    {
        const rgbas = try grays.toRGBAS(allo);
        defer rgbas.deinit(allo);
        const len = rgbas.len;
        for (0..len) |i| {
            const rgba = rgbas.get(i);
            const e_rgb = expected_rgbs[i];
            try std.testing.expectEqualDeep(
                rgba,
                RGBA{ .r = e_rgb.r, .g = e_rgb.g, .b = e_rgb.b },
            );
        }
    }
}
