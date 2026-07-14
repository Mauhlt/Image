const std = @import("std");
const GRAY = @import("pixel_format.zig").GRAY;
const RGB = @import("pixel_format.zig").RGB;
const RGBA = @import("pixel_format.zig").RGBA;

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
    GRAY.Order,
    RGB.Order,
    RGBA.Order,
}) catch unreachable;

pub const Pixels = union(PixelOrder) {
    grays: []GRAY,
    rgbs: []RGB,
    rgbas: []RGBA,

    pub fn initEmpty(
        gpa: std.mem.Allocator,
        pixel_order: PixelOrder,
        len: usize,
    ) !@This() {
        return switch (pixel_order) {
            .grays => .{ .grays = try gpa.alloc(GRAY, len) },
            .rgbs => .{ .rgbs = try gpa.alloc(RGB, len) },
            .rgbas => .{ .rgbas = try gpa.alloc(RGBA, len) },
        };
    }

    pub fn init(
        gpa: std.mem.Allocator,
        data: []const u8,
        data_order: DataOrder,
        pixel_order: PixelOrder,
    ) !@This() {
        return switch (pixel_order) {
            .grays => {
                if (data.len == 0) return error.InvalidDataLength;
                const len = data.len;
                const pxs: @This() = try .initEmpty(gpa, pixel_order, len);
                for (0..len) |i| {
                    pxs.grays[i] = .init(data[i]);
                }
                return pxs;
            },
            .rgbs => {
                if (@mod(data.len, 3) != 0) return error.InvalidDataLength;
                if (data.len == 0) return error.InvalidDataLength;
                const len = data.len / 3;
                const pxs: @This() = try .initEmpty(gpa, pixel_order, len);
                for (0..len) |i| {
                    pxs.rgbs[i] = .initOrder(
                        data[i * 3 ..][0..3],
                        @enumFromInt(@intFromEnum(data_order)),
                    );
                }
                return pxs;
            },
            .rgbas => {
                if (@mod(data.len, 4) != 0) return error.InvalidDataLength;
                if (data.len == 0) return error.InvalidDataLength;
                const len = data.len / 4;
                const pxs: @This() = try .initEmpty(gpa, pixel_order, len);
                for (0..len) |i| {
                    pxs.rgbas[i] = .initOrder(
                        data[i * 4 ..][0..4],
                        @enumFromInt(@intFromEnum(data_order)),
                    );
                }
                return pxs;
            },
        };
    }

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            .grays => |grays| gpa.free(grays),
            .rgbs => |rgbs| gpa.free(rgbs),
            .rgbas => |rgbas| gpa.free(rgbas),
        }
    }

    pub fn dupe(self: @This(), gpa: std.mem.Allocator) !@This() {
        return switch (self) {
            .grays => |grays| .{ .grays = try gpa.dupe(GRAY, grays) },
            .rgbs => |rgbs| .{ .rgbs = try gpa.dupe(RGB, rgbs) },
            .rgbas => |rgbas| .{ .rgbas = try gpa.dupe(RGBA, rgbas) },
        };
    }

    pub fn toGRAYS(self: @This(), gpa: std.mem.Allocator) !@This() {
        switch (self) {
            .grays => return self.dupe(gpa),
            .rgbs => |rgbs| {
                const pxs: @This() = try .initEmpty(gpa, .grays, rgbs.len);
                for (0..rgbs.len) |i| {
                    pxs.grays[i] = rgbs[i].pixel.toGRAY16();
                }
                return pxs;
            },
            .rgbas => |rgbas| {
                const pxs: @This() = try .initEmpty(gpa, .grays, rgbas.len);
                for (0..rgbas.len) |i| {
                    pxs.grays[i] = rgbas[i].pixel.toGRAY16();
                }
                return pxs;
            },
        }
    }

    pub fn toRGBS(self: @This(), gpa: std.mem.Allocator) !@This() {
        switch (self) {
            .grays => |grays| {
                const pxs: @This() = try .initEmpty(gpa, .rgbs, grays.len);
                for (0..grays.len) |i| {
                    pxs.rgbs[i] = grays[i].pixel.toRGB();
                }
                return pxs;
            },
            .rgbs => return self.dupe(gpa),
            .rgbas => |rgbas| {
                const pxs: @This() = try .initEmpty(gpa, .rgbs, rgbas.len);
                for (0..rgbas.len) |i| {
                    pxs.rgbs[i] = rgbas[i].pixel.toRGB();
                }
                return pxs;
            },
        }
    }

    pub fn toRGBAS(self: @This(), gpa: std.mem.Allocator) !@This() {
        switch (self) {
            .grays => |grays| {
                const pxs: @This() = try .initEmpty(gpa, .rgbas, grays.len);
                for (0..grays.len) |i| {
                    pxs.rgbas[i] = grays[i].pixel.toRGBA();
                }
                return pxs;
            },
            .rgbs => |rgbs| {
                const pxs: @This() = try .initEmpty(gpa, .rgbas, rgbs.len);
                for (0..rgbs.len) |i| {
                    pxs.rgbas[i] = rgbs[i].pixel.toRGBA();
                }
                return pxs;
            },
            .rgbas => return self.dupe(gpa),
        }
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

    // pixels
    const gpa = std.testing.allocator;
    const da: DataOrder = .g;
    const data = [_]u8{ 100, 25, 75, 175, 225 };

    const base_pxs: Pixels = try .init(gpa, &data, da, .grays);
    defer base_pxs.deinit(gpa);

    { // grays
        const gray_pxs = try base_pxs.toGRAYS(gpa);
        defer gray_pxs.deinit(gpa);
        // grays -> rgbs
        const rgb_pxs = try gray_pxs.toRGBS(gpa);
        defer rgb_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const rgb_act = rgb_pxs.rgbs[i].pixel.toU32();
            const rgb_exp = @as(u32, data[i]) << 24 | //
                @as(u32, data[i]) << 16 | //
                @as(u32, data[i]) << 8 | //
                0x0000_00FF;
            try std.testing.expectEqual(rgb_exp, rgb_act);
        }
        // grays -> rgbas
        const rgba_pxs = try base_pxs.toRGBAS(gpa);
        defer rgba_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const rgba_act = rgba_pxs.rgbas[i].pixel.toU32();
            const rgba_exp: u32 = @as(u32, data[i]) << 24 | //
                @as(u32, data[i]) << 16 | //
                @as(u32, data[i]) << 8 | //
                0xFF;
            try std.testing.expectEqual(rgba_exp, rgba_act);
        }
    }

    { // rgbs
        const rgb_pxs = try base_pxs.toRGBS(gpa);
        defer rgb_pxs.deinit(gpa);
        // rgbs -> grays
        const gray_pxs = try rgb_pxs.toGRAYS(gpa);
        defer gray_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const gray_act = gray_pxs.grays[i].pixel.toU32();
            const gray_exp: u8 = data[i];
            try std.testing.expectEqualDeep(gray_exp, gray_act);
        }
        // rgbs -> rgbas
        const rgba_pxs = try rgb_pxs.toRGBAS(gpa);
        defer rgba_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const rgba_act = rgba_pxs.rgbas[i].pixel.toU32();
            const rgba_exp: u32 = @as(u32, data[i]) << 24 | //
                @as(u32, data[i]) << 16 | //
                @as(u32, data[i]) << 8 | //
                0xFF;
            try std.testing.expectEqual(rgba_exp, rgba_act);
        }
    }

    { // rgbas
        const rgba_pxs = try base_pxs.toRGBAS(gpa);
        defer rgba_pxs.deinit(gpa);
        // rgbas -> grays
        const gray_pxs = try rgba_pxs.toGRAYS(gpa);
        defer gray_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const gray_act = gray_pxs.grays[i].pixel.toU32();
            const gray_exp = data[i];
            try std.testing.expectEqual(gray_exp, gray_act);
        }
        // rgbas -> rgbs
        const rgb_pxs = try rgba_pxs.toRGBS(gpa);
        defer rgb_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const rgb_act = rgb_pxs.rgbs[i].pixel.toU32();
            const rgb_exp = @as(u32, data[i]) << 24 | //
                @as(u32, data[i]) << 16 | //
                @as(u32, data[i]) << 8 | //
                0xFF;
            try std.testing.expectEqualDeep(rgb_exp, rgb_act);
        }
    }
}
