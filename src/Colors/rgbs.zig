const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @import("rgbas.zig");
const RGBS = @This();

const Order = RGB.Order;

r: [*]u8,
g: [*]u8,
b: [*]u8,
len: usize,

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBS {
    const field_names = comptime std.meta.fieldNames(RGB);
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
        inline for (0..n_fields) |k| {
            rgbs[i + len * k] = @field(rgb, field_names[k]);
        }
    }

    return .{
        .r = rgbs.ptr,
        .g = @ptrFromInt(@intFromPtr(rgbs.ptr) + len),
        .b = @ptrFromInt(@intFromPtr(rgbs.ptr) + len),
    };
}

pub fn deinit(self: *const RGBS, gpa: std.mem.Allocator) void {
    gpa.free(self.r[0 .. self.len * 3]);
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
