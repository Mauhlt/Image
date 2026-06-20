const std = @import("std");

const GRAY = @import("gray.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @import("rgbas.zig");

const GRAYS = @This();

slice: []GRAY,

pub fn init(gpa: std.mem.Allocator, data: []const u8) !GRAYS {
    const grays: []GRAY = @ptrCast(try gpa.dupe(u8, data));
    return .{ .slice = grays };
}

pub fn deinit(self: GRAYS, gpa: std.mem.Allocator) void {
    gpa.free(self.slice);
}

pub fn toRGBS(grays: GRAYS, gpa: std.mem.Allocator) !RGBS {
    var rgbs = try gpa.alloc(RGB, grays.slice.len);
    for (0..rgbs.len) |i| rgbs[i] = grays.slice[i].toRGB();
    return .{ .slice = rgbs };
}

pub fn toRGBAS(grays: GRAYS, gpa: std.mem.Allocator) !RGBAS {
    var rgbas = try gpa.alloc(RGBA, grays.slice.len);
    for (0..rgbas.len) |i| rgbas[i] = grays.slice[i].toRGBA();
    return .{ .slice = rgbas };
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

    const rgbs = try grays.toRGBS(allo);
    defer rgbs.deinit(allo);
    for (rgbs.slice, expected_rgbs) |rgb, e_rgb| {
        try std.testing.expectEqualDeep(rgb, e_rgb);
    }

    const rgbas = try grays.toRGBAS(allo);
    defer rgbas.deinit(allo);
    for (rgbas.slice, expected_rgbs) |rgba, e_rgb| {
        try std.testing.expectEqualDeep(rgba, RGBA{ .r = e_rgb.r, .g = e_rgb.g, .b = e_rgb.b });
    }
}
