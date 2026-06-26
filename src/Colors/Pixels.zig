const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("rgbs.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @import("rgbas.zig");

const PixelOrder = enum(u8) {
    gray,
    rgb,
    rgba,
};

/// Returns Enum that is a superset
fn MergeEnums(comptime types: []const type) !type {
    for (types) |t| {
        switch (@typeInfo(t)) {
            .@"enum" => {},
            else => @compileError("Invalid Type. Fn accepts enums only"),
        }
    }
    comptime {
        const first_tag_type = @typeInfo(types[0]).@"enum".tag_type;
        for (types[1..]) |t| {
            if (@typeInfo(t).@"enum".tag_type != first_tag_type) //
                return error.MismatchingEnumTagType;
        }

        for (0..types.len - 1) |i| {
            const fields1 = @typeInfo(types[i]).@"enum".fields;
            for (i + 1..types.len) |j| {
                const fields2 = @typeInfo(types[j]).@"enum".fields;
                for (fields1) |field1| {
                    for (fields2) |field2| {
                        if (std.mem.eql(u8, field1.name, field2.name)) //
                            return error.EnumNameIsNotUnique;
                        if (field1.value == field2.value) //
                            return error.EnumValueIsNotUnique;
                    }
                }
            }
        }

        var n_fields: usize = @typeInfo(types[0]).@"enum".fields.len;
        for (types[1..]) |t| {
            n_fields += @typeInfo(t).@"enum".fields.len;
        }

        var names: [n_fields][]const u8 = undefined;
        var values: [n_fields]u8 = undefined;
        var i: usize = 0;
        for (types) |t| {
            for (@typeInfo(t).@"enum".fields) |enum_field| {
                names[i] = enum_field.name;
                values[i] = enum_field.value;
                i += 1;
            }
        }

        return @Enum(
            @typeInfo(types[0]).@"enum".tag_type,
            .exhaustive,
            &names,
            &values,
        );
    }
}

const DataOrder: type = MergeEnums(&.{ GRAY.Order, RGB.Order, RGBA.Order }) catch unreachable;

fn computeStride(data_order: DataOrder) usize {
    return @tagName(data_order).len;
}

pub const Pixels = union(PixelOrder) {
    gray: GRAYS,
    rgb: RGBS,
    rgba: RGBAS,

    pub fn init(
        allo: std.mem.Allocator,
        data: []const u8,
        data_order: DataOrder,
        pixel_order: PixelOrder,
    ) !@This() {
        const in_data: Pixels = switch (data_order) {
            .g => .{ .gray = try .init(allo, data) },
            .rgb, .rbg, .grb, .gbr, .brg, .bgr => .{ .rgb = try .init(allo, data, @enumFromInt(@intFromEnum(data_order))) },
            else => .{ .rgba = try .init(allo, data, @enumFromInt(@intFromEnum(data_order))) },
        };
        switch (pixel_order) {
            .gray => switch (in_data) {
                .gray => return in_data,
                .rgb => |rgbs| {
                    defer in_data.deinit(allo);
                    return .{ .gray = try rgbs.toGRAYS(allo) };
                },
                .rgba => |rgbas| {
                    defer in_data.deinit(allo);
                    return .{ .gray = try rgbas.toGRAYS(allo) };
                },
            },
            .rgb => switch (in_data) {
                .gray => |grays| {
                    defer in_data.deinit(allo);
                    return .{ .rgb = try grays.toRGBS(allo) };
                },
                .rgb => return in_data,
                .rgba => |rgbas| {
                    defer in_data.deinit(allo);
                    return .{ .rgb = try rgbas.toRGBS(allo) };
                },
            },
            .rgba => switch (in_data) {
                .gray => |grays| {
                    defer in_data.deinit(allo);
                    return .{ .rgba = try grays.toRGBAS(allo) };
                },
                .rgb => |rgbs| {
                    defer in_data.deinit(allo);
                    return .{ .rgba = try rgbs.toRGBAS(allo) };
                },
                .rgba => return in_data,
            },
        }
    }

    pub fn deinit(
        self: @This(),
        allo: std.mem.Allocator,
    ) void {
        switch (self) {
            .gray => |grays| grays.deinit(allo),
            .rgb => |rgbs| rgbs.deinit(allo),
            .rgba => |rgbas| rgbas.deinit(allo),
        }
    }

    pub fn convert(
        self: @This(),
        allo: std.mem.Allocator,
        order: PixelOrder,
    ) !@This() {
        return switch (self) {
            .gray => |grays| switch (order) {
                .gray => .{ .gray = try grays.dupe(allo) },
                .rgb => .{ .rgb = try grays.toRGBS(allo) },
                .rgba => .{ .rgba = try grays.toRGBAS(allo) },
            },
            .rgb => |rgbs| switch (order) {
                .gray => .{ .gray = try rgbs.toGRAYS(allo) },
                .rgb => .{ .rgb = try rgbs.dupe(allo) },
                .rgba => .{ .rgba = try rgbs.toRGBAS(allo) },
            },
            .rgba => |rgbas| switch (order) {
                .gray => .{ .gray = try rgbas.toGRAYS(allo) },
                .rgb => .{ .rgb = try rgbas.toRGBS(allo) },
                .rgba => .{ .rgba = try rgbas.dupe(allo) },
            },
        };
    }
};

test "Pixels" {
    @setEvalBranchQuota(10_000);
    const da_fields = std.meta.fields(DataOrder);
    const g_fields = std.meta.fields(GRAY.Order);
    inline for (g_fields) |field1| {
        var found_match: bool = false;
        inline for (da_fields) |field2| {
            if (std.mem.eql(u8, field1.name, field2.name)) {
                try std.testing.expectEqual(field1.value, field2.value);
                found_match = true;
            }
        }
        try std.testing.expectEqual(found_match, true);
    }
    const rgb_fields = std.meta.fields(RGB.Order);
    inline for (rgb_fields) |field1| {
        var found_match: bool = false;
        inline for (da_fields) |field2| {
            if (std.mem.eql(u8, field1.name, field2.name)) {
                try std.testing.expectEqual(field1.value, field2.value);
                found_match = true;
            }
        }
        try std.testing.expectEqual(found_match, true);
    }
    const rgba_fields = std.meta.fields(RGBA.Order);
    inline for (rgba_fields) |field1| {
        var found_match: bool = false;
        inline for (da_fields) |field2| {
            if (std.mem.eql(u8, field1.name, field2.name)) {
                try std.testing.expectEqual(field1.value, field2.value);
                found_match = true;
            }
        }
        try std.testing.expectEqual(found_match, true);
    }
    // compute strides
    inline for (da_fields) |field| {
        const da2 = @field(DataOrder, field.name);
        const cs = computeStride(da2);
        const cs2 = @tagName(da2).len;
        try std.testing.expectEqual(cs, cs2);
    }
    // pixels
    const gpa = std.testing.allocator;
    const da: DataOrder = .g;
    const data = [_]u8{ 100, 25, 75, 175, 225 };

    // grays -> rgb/rgba

    {
        const grays: Pixels = try .init(gpa, &data, da, .gray);
        defer grays.deinit(gpa);
        const rgbs = try grays.convert(gpa, .rgb);
        defer rgbs.deinit(gpa);
        for (0..data.len) |i| {
            const rgb1 = try rgbs.rgb.get(i);
            const rgb2 = RGB{ .r = data[i], .g = data[i], .b = data[i] };
            try std.testing.expectEqualDeep(rgb1, rgb2);
        }
    }

    {
        const grays: Pixels = try .init(gpa, &data, da, .gray);
        defer grays.deinit(gpa);
        const rgbas = try grays.convert(gpa, .rgba);
        defer rgbas.deinit(gpa);
        for (0..data.len) |i| {
            const rgba1 = try rgbas.rgba.get(i);
            const rgba2: RGBA = .{ .r = data[i], .g = data[i], .b = data[i], .a = 255 };
            try std.testing.expectEqualDeep(rgba1, rgba2);
        }
    }

    // rgb -> gray/rgba
    {
        const grays: Pixels = try .init(gpa, &data, da, .gray);
        defer grays.deinit(gpa);
        const rgbs = try grays.convert(gpa, .rgb);
        defer rgbs.deinit(gpa);
        const grays2 = try rgbs.convert(gpa, .gray);
        defer grays2.deinit(gpa);
        for (0..data.len) |i| {
            const gray1 = try grays2.gray.get[i];
            const gray2: GRAY = .{ .g = data[i] };
            try std.testing.expectEqualDeep(gray1, gray2);
        }
    }

    {
        const rgbas2 = try rgbs1.convert(gpa, .rgba);
        defer rgbas2.deinit(gpa);
        for (0..data.len) |i| {
            try std.testing.expectEqualDeep(rgbas2.rgba.slice[i], RGBA{ .r = data[i], .g = data[i], .b = data[i], .a = 255 });
        }
    }

    // rgba -> gray/rgb
    const rgbs3 = try rgbas1.convert(gpa, .rgb);
    defer rgbs3.deinit(gpa);
    for (0..data.len) |i| {
        try std.testing.expectEqualDeep(rgbs3.rgb.slice[i], RGB{ .r = data[i], .g = data[i], .b = data[i] });
    }

    const grays3 = try rgbas1.convert(gpa, .gray);
    defer grays3.deinit(gpa);
    for (0..data.len) |i| {
        try std.testing.expectEqualDeep(grays3.gray.slice[i], GRAY{ .g = data[i] });
    }
}
