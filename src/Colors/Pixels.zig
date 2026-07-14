const std = @import("std");
const GRAYS = @import("pixels_format.zig").GRAYS;
const RGBS = @import("pixels_format.zig").RGBS;
const RGBAS = @import("pixels_format.zig").RGBAS;

const PixelOrder = enum(u8) {
    grays,
    rgbs,
    rgbas,
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

const DataOrder: type = MergeEnums(&.{
    GRAYS.Order,
    RGBS.Order,
    RGBAS.Order,
}) catch unreachable;

pub const Pixels = union(PixelOrder) {
    grays: GRAYS,
    rgbs: RGBS,
    rgbas: RGBAS,

    pub fn initEmpty(
        gpa: std.mem.Allocator,
        pixel_order: PixelOrder,
        n_pixels: usize,
    ) !@This() {
        return switch (pixel_order) {
            .gray => .{ .grays = try .initEmpty(gpa, n_pixels) },
            .rgb => .{ .rgbs = try .initEmpty(gpa, n_pixels) },
            .rgba => .{ .rgbas = try .initEmpty(gpa, n_pixels) },
        };
    }

    pub fn init(
        gpa: std.mem.Allocator,
        data: []const u8,
        data_order: DataOrder,
        pixel_order: PixelOrder,
    ) !@This() {
        const in_data: Pixels = switch (data_order) {
            .g => .{ .grays = try .init(gpa, data) },
            .rgb, .rbg, .grb, .gbr, .brg, .bgr => //
            .{ .rgbs = try .init(gpa, data, @enumFromInt(@intFromEnum(data_order))) },
            else => .{ .rgbas = try .init(gpa, data, @enumFromInt(@intFromEnum(data_order))) },
        };
        switch (pixel_order) {
            .gray => switch (in_data) {
                .gray => return in_data,
                .rgb => |rgbs| {
                    defer in_data.deinit(gpa);
                    return .{ .grays = try rgbs.toGRAYS(gpa) };
                },
                .rgba => |rgbas| {
                    defer in_data.deinit(gpa);
                    return .{ .grays = try rgbas.toGRAYS(gpa) };
                },
            },
            .rgb => switch (in_data) {
                .gray => |grays| {
                    defer in_data.deinit(gpa);
                    return .{ .rgbs = try grays.toRGBS(gpa) };
                },
                .rgb => return in_data,
                .rgba => |rgbas| {
                    defer in_data.deinit(gpa);
                    return .{ .rgbs = try rgbas.toRGBS(gpa) };
                },
            },
            .rgba => switch (in_data) {
                .gray => |grays| {
                    defer in_data.deinit(gpa);
                    return .{ .rgbas = try grays.toRGBAS(gpa) };
                },
                .rgb => |rgbs| {
                    defer in_data.deinit(gpa);
                    return .{ .rgbas = try rgbs.toRGBAS(gpa) };
                },
                .rgba => return in_data,
            },
        }
    }

    pub fn deinit(
        self: @This(),
        gpa: std.mem.Allocator,
    ) void {
        switch (self) {
            .gray => |grays| grays.deinit(gpa),
            .rgb => |rgbs| rgbs.deinit(gpa),
            .rgba => |rgbas| rgbas.deinit(gpa),
        }
    }

    pub fn convert(
        self: @This(),
        gpa: std.mem.Allocator,
        order: PixelOrder,
    ) !@This() {
        return switch (self) {
            .gray => |grays| switch (order) {
                .gray => .{ .grays = try grays.dupe(gpa) },
                .rgb => .{ .rgbs = try grays.toRGBS(gpa) },
                .rgba => .{ .rgbas = try grays.toRGBAS(gpa) },
            },
            .rgb => |rgbs| switch (order) {
                .gray => .{ .grays = try rgbs.toGRAYS(gpa) },
                .rgb => .{ .rgbs = try rgbs.dupe(gpa) },
                .rgba => .{ .rgbas = try rgbs.toRGBAS(gpa) },
            },
            .rgba => |rgbas| switch (order) {
                .gray => .{ .grays = try rgbas.toGRAYS(gpa) },
                .rgb => .{ .rgbs = try rgbas.toRGBS(gpa) },
                .rgba => .{ .rgbas = try rgbas.dupe(gpa) },
            },
        };
    }
};

test "Pixels" {
    @setEvalBranchQuota(10_000);
    const da_fields = std.meta.fields(DataOrder);
    const g_fields = std.meta.fields(GRAYS.Order);
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
    const rgb_fields = std.meta.fields(RGBS.Order);
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
    const rgba_fields = std.meta.fields(RGBAS.Order);
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
    // pixels
    const gpa = std.testing.allocator;
    const da: DataOrder = .g;
    const data = [_]u8{ 100, 25, 75, 175, 225 };

    const base: Pixels = try .init(gpa, &data, da, .gray);
    defer base.deinit(gpa);

    { // grays
        const grays = try base.convert(gpa, .gray);
        defer grays.deinit(gpa);
        // grays -> rgbs
        const rgbs = try grays.convert(gpa, .rgb);
        defer rgbs.deinit(gpa);
        for (0..data.len) |i| {
            const rgb1 = try rgbs.rgb.get(i);
            const rgb2 = RGB{ .r = data[i], .g = data[i], .b = data[i] };
            try std.testing.expectEqualDeep(rgb1, rgb2);
        }
        // grays -> rgbas
        const rgbas = try grays.convert(gpa, .rgba);
        defer rgbas.deinit(gpa);
        for (0..data.len) |i| {
            const rgba1 = try rgbas.rgba.get(i);
            const rgba2: RGBA = .{ .r = data[i], .g = data[i], .b = data[i], .a = 255 };
            try std.testing.expectEqualDeep(rgba1, rgba2);
        }
    }

    { // rgbs
        const rgbs = try base.convert(gpa, .rgb);
        defer rgbs.deinit(gpa);
        // rgbs -> grays
        const grays = try rgbs.convert(gpa, .gray);
        defer grays.deinit(gpa);
        for (0..data.len) |i| {
            const gray1 = try grays.gray.get(i);
            const gray2: GRAY = .{ .g = data[i] };
            try std.testing.expectEqualDeep(gray1, gray2);
        }
        // rgbs -> rgbas
        const rgbas = try rgbs.convert(gpa, .rgba);
        defer rgbas.deinit(gpa);
        for (0..data.len) |i| {
            const rgba1 = try rgbas.rgba.get(i);
            const rgba2: RGBA = .{ .r = data[i], .g = data[i], .b = data[i], .a = 255 };
            try std.testing.expectEqualDeep(rgba1, rgba2);
        }
    }

    { // rgbas
        const rgbas = try base.convert(gpa, .rgba);
        defer rgbas.deinit(gpa);
        // rgbas -> grays
        const grays = try rgbas.convert(gpa, .gray);
        defer grays.deinit(gpa);
        for (0..data.len) |i| {
            const gray1 = grays.grays.slice[i];
            const gray1 = try grays.gray.get(i);
            const gray2: GRAY = .{ .g = data[i] };
            try std.testing.expectEqualDeep(gray1, gray2);
        }
        // rgbas -> rgbs
        const rgbs = try rgbas.convert(gpa, .rgb);
        defer rgbs.deinit(gpa);
        for (0..data.len) |i| {
            const rgb1 = rgbs.rgb.get(i);
            const rgb2: RGB = .{ .r = data[i], .g = data[i], .b = data[i] };
            try std.testing.expectEqualDeep(rgb1, rgb2);
        }
    }
}
