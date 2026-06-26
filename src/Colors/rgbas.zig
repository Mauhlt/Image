const std = @import("std");

const POSITION = @import("position.zig");
const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @This();

const Order = RGBA.Order;
const field_names = std.meta.fieldNames(RGBA);

// organized r.. g.. b.. a..
ptr: [*]u8, // ptr to start of r
len: usize = 0, // len of 1 field

pub fn initEmpty(gpa: std.mem.Allocator, len: usize) !RGBAS {
    if (len == 0) return error.InvalidDataLen;
    const rgbas = try gpa.alloc(u8, len * field_names.len);
    errdefer gpa.free(rgbas);
    return .{
        .ptr = rgbas.ptr,
        .len = len,
    };
}

pub fn init(gpa: std.mem.Allocator, data: []const u8, order: Order) !RGBAS {
    if (data.len == 0) return error.InvalidDataLen;
    if (@mod(data.len, field_names.len) != 0) return error.InvalidDataLen;
    const len = data.len / field_names.len;

    const rgbas = try gpa.alloc(u8, data.len);
    errdefer gpa.free(rgbas);

    var i: usize = 0;
    var j: usize = 0;
    while (i < len) : ({
        i += 1;
        j += field_names.len;
    }) {
        const rgba: RGBA = .initOrder(data[j..][0..field_names.len], order);
        inline for (field_names, 0..) |field_name, k| {
            rgbas.ptr[i + len * k] = @field(rgba, field_name);
        }
    }

    return .{
        .ptr = rgbas.ptr,
        .len = rgbas.len,
    };
}

pub fn dupe(self: RGBAS, gpa: std.mem.Allocator) !RGBAS {
    const rgbas = try gpa.dupe(u8, self.ptr[0 .. self.len * field_names.len]);
    return .{
        .ptr = rgbas.ptr,
        .len = self.len,
    };
}

pub fn deinit(self: RGBAS, gpa: std.mem.Allocator) void {
    gpa.free(self.ptr[0 .. self.len * field_names.len]);
}

pub fn replace(self: RGBAS, i: usize, rgba: RGBA) !void {
    if (i >= self.len) return error.OutOfBounds;
    inline for (field_names, 0..) |field_name, k| {
        self.ptr[i + k * self.len] = @field(rgba, field_name);
    }
}

pub fn get(self: RGBAS, i: usize) !RGBA {
    if (i >= self.len) return error.OutOfBounds;
    var rgba: RGBA = undefined;
    inline for (field_names, 0..) |field_name, k| {
        @field(rgba, field_name) = self.ptr[i + k * self.len];
    }
    return rgba;
}

pub fn slice(
    self: RGBAS,
    allo: std.mem.Allocator,
    pos: POSITION,
) ![]RGBA {
    if (pos.start == 0 and pos.end == 0) {
        const rgbas = try allo.alloc(RGBA, self.len);
        for (0..self.len) |i| rgbas[i] = try self.get(i);
        return rgbas;
    }

    if (pos.end <= pos.start) return error.InvalidPosition;
    if (pos.end > self.len) return error.OutOfBounds;

    const len = pos.end - pos.start;
    const rgbas = try allo.dupe(RGBAS, len);
    for (0..len) |i| rgbas[i] = try self.get(pos.start + i);
    return rgbas;
}

pub fn toGRAYS(self: RGBAS, gpa: std.mem.Allocator) !GRAYS {
    const grays: GRAYS = try .initEmpty(gpa, self.len);
    for (0..self.len) |i| grays.replace(i, (try self.get(i)).toGrayFast16());
    return grays;
}

pub fn toRGBS(self: RGBAS, gpa: std.mem.Allocator) !RGBS {
    const rgbs: RGBS = try .initEmpty(gpa, self.len);
    for (0..self.len) |i| rgbs.replace(i, (try self.get(i)).toRGB());
    return rgbs;
}

// test "RGBAS" {
//     const allo = std.testing.allocator;
//     const data = [_]u8{ 255, 100, 0, 10 };
//
//     {
//         const rgbas: RGBAS = try .init(allo, &data, .rgba);
//         defer rgbas.deinit(allo);
//         try std.testing.expectEqualDeep(
//             rgbas.get(0),
//             RGBA{ .r = data[0], .g = data[1], .b = data[2], .a = data[3] },
//         );
//     }
//
//     {
//         const rgbas: RGBAS = try .init(allo, &data, .abgr);
//         defer rgbas.deinit(allo);
//         try std.testing.expectEqualDeep(
//             rgbas.get(0),
//             RGBA{ .r = data[3], .g = data[2], .b = data[1], .a = data[0] },
//         );
//     }
//
//     {
//         const grays = try rgbas.toGRAYS(allo);
//         defer grays.deinit(allo);
//         try std.testing.expectEqualDeep(grays.slice[0], GRAY{ .g = 134 });
//     }
//
//     {
//         const rgbs = try rgbas.toRGBS(allo);
//         defer rgbs.deinit(allo);
//         try std.testing.expectEqualDeep(
//             rgbs.slice[0],
//             RGB{ .r = data[0], .g = data[1], .b = data[2] },
//         );
//     }
// }
