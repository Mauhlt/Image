const std = @import("std");

const GRAY = @import("gray.zig");
const RGB = @import("rgb.zig").RGB;
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig").RGBA;
const RGBAS = @import("rgbas.zig");
const GRAYS = @This();

g: [*]GRAY,
len: usize,

pub fn init(gpa: std.mem.Allocator, data: []const u8) !GRAYS {
    const grays: []GRAY = @ptrCast(try gpa.dupe(u8, data));
    return .{
        .g_ptr = grays.ptr,
        .len = grays.len,
    };
}

pub fn deinit(self: GRAYS, gpa: std.mem.Allocator) void {
    gpa.free(self.data[0..self.len]);
}

pub fn toRGBS(grays: GRAYS, gpa: std.mem.Allocator) !RGBS {
    const len = grays.data.len;
    var rgbs: RGBS = try .initEmpty(gpa, len << 2);
    for (0..len) |i| {
        const rgb = grays.g_ptr[i].toRGB();
        rgbs.replaceAt();
    }
    return .{ .data = rgbs };
}

pub fn toRGBAS(grays: GRAYS, gpa: std.mem.Allocator) !RGBAS {
    const len = grays.data.len;
    var rgbas = try gpa.alloc(u8, len * 4);
    for (0..len) |i| {
        replaceAtIndex(self: *const RGBAS, i: usize, rgba: RGBA) !void {
        const rgba = grays.data[i].toRGBA();
        rgbas[i] = rgb.r;
        rgbas[i + len] = rgb.g;
    }
    return .{ .data = rgbas };
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
    const len1 = rgbs.data.len;
    for (0..len1) |i| {
        const rgb = rgbs.data.get(i);
        const e_rgb = expected_rgbs[i];
        try std.testing.expectEqualDeep(rgb, e_rgb);
    }

    const rgbas = try grays.toRGBAS(allo);
    defer rgbas.deinit(allo);
    const len2 = rgbas.data.len;
    for (0..len2) |i| {
        const rgba = rgbas.data.get(i);
        const e_rgb = expected_rgbs[i];
        try std.testing.expectEqualDeep(
            rgba,
            RGBA{ .r = e_rgb.r, .g = e_rgb.g, .b = e_rgb.b },
        );
    }
}
