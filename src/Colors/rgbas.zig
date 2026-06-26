const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @This();

const Order = RGBA.Order;
const field_names = std.meta.fieldNames(RGBA);

ptr: [*]u8,
len: usize,

pub fn allocEmpty(gpa: std.mem.Allocator, len: usize) !RGBAS {
    if (len == 0) return error.InvalidDataLen;
    const rgbas = try gpa.alloc(u8, len * 4);
    return .{
        .ptr = rgbas.ptr,
        .len = rgbas.len,
    };
}

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBAS {
    if (data.len == 0) return error.InvalidDataLen;
    if (@mod(data.len, field_names.len) != 0) //
        return error.InvalidDataLen;
    const len = data.len / field_names.len;

    const new_data = try gpa.alloc(u8, len * field_names.len);
    errdefer gpa.free(new_data);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += field_names.len;
    }) {
        const rgba: RGBA = .initOrder(data[j..][0..field_names.len], order);
        inline for (0..field_names.len) |k| {
            new_data[i + len * k] = @field(rgba, field_names[k]);
        }
    }

    return .{
        .r = data.ptr,
        .g = @ptrFromInt(@intFromPtr(data.ptr) + len),
        .b = @ptrFromInt(@intFromPtr(data.ptr) + 2 * len),
        .a = @ptrFromInt(@intFromPtr(data.ptr) + 3 * len),
        .len = len,
    };
}

pub fn deinit(self: *const RGBAS, gpa: std.mem.Allocator) void {
    gpa.free(self.r[0 .. self.len * 4]);
}

pub fn replaceAt(self: *const RGBAS, i: usize, rgba: RGBA) !void {
    if (i > (self.len >> 2)) return error.OutOfBounds;
    inline for (std.meta.fieldNames(RGBA), 0..) |field_name, k| {
        @field(self, field_name)[i + k * self.len] = @field(rgba, field_name);
    }
}

pub fn toGRAYS(rgbas: RGBAS, gpa: std.mem.Allocator) !GRAYS {
    const len = rgbas.data.len;
    var grays = try gpa.alloc(GRAY, len);
    for (0..len) |i| grays[i] = rgbas.data.get(i).toGrayFast16();
    return .{ .data = grays };
}

pub fn toRGBS(rgbas: RGBAS, gpa: std.mem.Allocator) !RGBS {
    const len = rgbas.data.len;
    var rgbs: std.MultiArrayList(RGB) = try .initCapacity(gpa, len);
    for (0..len) |i| rgbs[i] = rgbas.data.get(i).toRGB();
    return .{ .data = rgbs };
}

test "RGBAS" {
    const allo = std.testing.allocator;
    const data = [_]u8{ 255, 100, 0, 10 };

    const rgbas: RGBAS = try .init(allo, &data, .rgba);
    defer rgbas.deinit(allo);
    try std.testing.expectEqualDeep(
        rgbas.data.get(0),
        RGBA{ .r = data[0], .g = data[1], .b = data[2], .a = data[3] },
    );

    const rgbas2: RGBAS = try .init(allo, &data, .abgr);
    defer rgbas2.deinit(allo);
    try std.testing.expectEqualDeep(
        rgbas2.slice[0],
        RGBA{ .r = data[3], .g = data[2], .b = data[1], .a = data[0] },
    );

    const grays = try rgbas.toGRAYS(allo);
    defer grays.deinit(allo);
    try std.testing.expectEqualDeep(grays.slice[0], GRAY{ .g = 134 });

    const rgbs = try rgbas.toRGBS(allo);
    defer rgbs.deinit(allo);
    try std.testing.expectEqualDeep(
        rgbs.slice[0],
        RGB{ .r = data[0], .g = data[1], .b = data[2] },
    );
}
