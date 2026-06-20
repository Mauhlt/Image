const std = @import("std");

const GRAY = @import("gray.zig");
const GRAYS = @import("grays.zig");
const RGB = @import("rgb.zig");
const RGBS = @import("RGBS.zig");
const RGBA = @import("rgba.zig");
const RGBAS = @import("rgbas.zig");

const PixelOrder = enum(u8) {
    gray,
    rgb,
    rgba,
};

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

        const E = @Enum(
            @typeInfo(types[0]).@"enum".tag_type,
            .exhaustive,
            &names,
            &values,
        );

        return struct {
            tag: E,
            pub fn computeStride(self: @This()) usize {
                return @tagName(self.tag).len;
            }
        };
    }
}

const DataOrder: type = MergeEnums(&.{ GRAY.Order, RGB.Order, RGBA.Order }) catch unreachable;

pub const Pixels = union(PixelOrder) {
    gray: GRAYS,
    rgb: RGBS,
    rgba: RGBAS,

    pub fn init(
        gpa: std.mem.Allocator,
        data: []const u8,
        data_order: DataOrder,
        pixel_order: PixelOrder,
    ) !@This() {
        const in_data: Pixels = switch (data_order) {
            .g => .{ .gray = try .initMany(gpa, data) },
            .rgb, .rbg, .grb, .gbr, .brg, .bgr => .{ .rgb = try .initMany(gpa, data, data_order) },
            else => .{ .rgba = try .initMany(gpa, data, data_order) },
        };
        switch (pixel_order) {
            .gray => switch (data_order.tag) {
                .g => return in_data,
                .rgb, .rbg, .grb, .gbr, .brg, .bgr => |rgbs| {
                    defer in_data.deinit(gpa);
                    return .{ .gray = try rgbs.toGRAYS(gpa) };
                },
                else => |rgbas| {
                    defer gpa.free(in_data.rgba);
                    return .{ .gray = try rgbas.toGRAYS(gpa) };
                },
            },
            .rgb => switch (data_order) {
                .g => |grays| {
                    defer in_data.deinit(gpa);
                    return .{ .rgb = grays.toRGBS(gpa) };
                },
                .rgb, .rbg, .grb, .gbr, .brg, .bgr => return in_data,
                else => |rgbas| {
                    defer in_data.deinit(gpa);
                    return .{ .rgb = rgbas.toRGBS(gpa) };
                },
            },
            .rgba => switch (data_order) {
                .g => |grays| {
                    defer in_data.deinit(gpa);
                    return .{ .gray = try grays.toRGBAS(gpa) };
                },
                .rgb, .rbg, .grb, .gbr, .brg, .bgr => |rgbs| {
                    defer in_data.deinit(gpa);
                    return .{ .rgba = try rgbs.toRGBAS(gpa) };
                },
                else => return in_data,
            },
        }
    }

    pub fn deinit(self: *const @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            .gray => |grays| grays.deinit(gpa),
            .rgb => |rgbs| rgbs.deinit(gpa),
            .rgba => |rgbas| rgbas.deinit(gpa),
        }
    }
};

test "Pixels" {
    @setEvalBranchQuota(10_000);
    // correct enum fields
    const da: DataOrder = undefined;
    const da_fields = std.meta.fields(@TypeOf(da.tag));
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
        const da2: DataOrder = .{ .tag = @field(@TypeOf(da.tag), field.name) };
        const cs = da2.computeStride();
        const cs2 = @tagName(da2.tag).len;
        try std.testing.expectEqual(cs, cs2);
    }
    // pixels - i dont think this works
}
