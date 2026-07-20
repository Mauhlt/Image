const std = @import("std");

const GrayOrder = @import("pixel_format.zig").GrayOrder;
const RgbOrder = @import("pixel_format.zig").RgbOrder;
const RgbaOrder = @import("pixel_format.zig").RgbaOrder;

const GRAY = @import("pixel_format.zig").GRAY;
const RGB = @import("pixel_format.zig").RGB;
const BGR = @import("pixel_format.zig").BGR;
const RGBA = @import("pixel_format.zig").RGBA;
const BGRA = @import("pixel_format.zig").BGRA;

const PixelTag = enum(u8) {
    grays,
    rgbs,
    bgrs,
    rgbas,
    bgras,

    fn modCheck(self: PixelTag, data: []const u8) !void {
        return switch (self) {
            .grays => {},
            .rgbs, .bgrs => if (@mod(data.len, 3) != 0) error.InvalidDataLength else {},
            .rgbas, .bgras => if (@mod(data.len, 4) != 0) error.InvalidDataLength else {},
        };
    }

    fn alignOf(self: PixelTag) usize {
        return switch (self) {
            .grays => 1,
            .rgbs, .bgrs => 3,
            .rgbas, .bgras => 4,
        };
    }
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
    GrayOrder,
    RgbOrder,
    RgbaOrder,
}) catch unreachable;

pub const Pixels = union(PixelTag) {
    grays: []GRAY,
    rgbs: []RGB,
    bgrs: []BGR,
    rgbas: []RGBA,
    bgras: []BGRA,

    // fn childType(self: Pixels) type {
    //     return @FieldType(Pixels, @tagName(std.meta.activeTag(self)));
    //     // return switch (self) {
    //     //     inline else => |data| @typeInfo(@TypeOf(data)).pointer.child,
    //     // };
    // }

    fn length(self: Pixels) usize {
        return switch (self) {
            inline else => |data| data.len,
        };
    }

    /// Assumes data is:
    ///     - correct alignment (u24 vs u32)
    ///     - correct order (rgb vs bgr)
    pub fn init(
        comptime pixel_tag: PixelTag,
        gpa: std.mem.Allocator,
        data: []const u8,
    ) !Pixels {
        if (data.len == 0) return error.InvalidDataLength;
        try pixel_tag.modCheck(data);
        const T = @FieldType(Pixels, @tagName(pixel_tag));
        const slice: T = @ptrCast(try gpa.dupe(u8, data));
        const pixels = @unionInit(Pixels, @tagName(pixel_tag), slice);
        return pixels;
    }

    // pub fn initOrder(
    //     gpa: std.mem.Allocator,
    //     data: []const u8,
    //     data_order: DataOrder,
    //     pixel_order: PixelTag,
    // ) !@This() {
    //     if (data.len == 0) return error.InvalidDataLength;
    //     try pixel_order.modCheck(data);
    //     const n_bytes_per_pixel = pixel_order.alignOf();
    //     const len = data.len / n_bytes_per_pixel;
    //     var pixels = @unionInit(Pixels, @tagName(pixel_order), undefined);
    //     // const T = pixels.childType();
    //     switch (pixel_order) {
    //         inline else => {
    //             const slice = try gpa.alloc(T, len);
    //             for (0..len) |i| slice[i] = .initOrder(
    //                 data[i * n_bytes_per_pixel ..][0..n_bytes_per_pixel],
    //                 @enumFromInt(@intFromEnum(data_order)),
    //             );
    //         },
    //     }
    //     return pixels;
    // }

    pub fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        switch (self) {
            inline else => |data| gpa.free(data),
        }
    }

    pub fn dupe(self: @This(), gpa: std.mem.Allocator) !@This() {
        switch (self) {
            inline else => |data, tag| {
                const slice = try gpa.dupe(@TypeOf(data[0]), data);
                return @unionInit(Pixels, @tagName(tag), slice);
            },
        }
    }

    pub fn convertTo(
        self: @This(),
        comptime other_tag: PixelTag,
        gpa: std.mem.Allocator,
    ) !@This() {
        const len = self.length();
        switch (self) {
            inline else => |src, tag| {
                if (tag == other_tag) return self.dupe(gpa);
                const DstElem = std.meta.Elem(@FieldType(Pixels, @tagName(other_tag)));
                const method = comptime switch (other_tag) {
                    .grays => "toGray16",
                    .rgbs => "toRgb",
                    .rgbas => "toRgba",
                    .bgrs => "toBgr",
                    .bgras => "toBgras",
                };
                const dst = try gpa.alloc(DstElem, len);
                for (src, dst) |s, *d| d.* = @field(@TypeOf(s), method)(s);
                return @unionInit(Pixels, @tagName(other_tag), dst);
            }
        }
    }
};

test "Pixels" {
    @setEvalBranchQuota(10_000);
    const da_fields = std.meta.fields(DataOrder);
    const g_fields = std.meta.fields(GrayOrder);
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
    const rgb_fields = std.meta.fields(RgbOrder);
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
    const rgba_fields = std.meta.fields(RgbaOrder);
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
    // const da: DataOrder = .g;
    const data = [_]u8{ 100, 25, 75, 175, 225 };

    const base_pxs: Pixels = try .init(.grays, gpa, &data);
    defer base_pxs.deinit(gpa);

    { // grays
        const gray_pxs = try base_pxs.dupe(gpa);
        defer gray_pxs.deinit(gpa);
        // grays -> rgbs
        const rgb_pxs = try gray_pxs.convertTo(.rgbs, gpa);
        defer rgb_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const rgb_act: u24 = @bitCast(rgb_pxs.rgbs[i]);
            const rgb_exp: u24 = @bitCast(RGB{
                .red = data[i],
                .green = data[i],
                .blue = data[i],
            });
            try std.testing.expectEqual(rgb_exp, rgb_act);
        }
        // grays -> rgbas
        const rgba_pxs = try base_pxs.convertTo(.rgbas, gpa);
        defer rgba_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const rgba_act: u32 = @bitCast(rgba_pxs.rgbas[i]);
            const rgba_exp: u32 = @bitCast(RGBA{
                .red = data[i],
                .green = data[i],
                .blue = data[i],
            });
            try std.testing.expectEqual(rgba_exp, rgba_act);
        }
    }

    { // rgbs
        const rgb_pxs = try base_pxs.convertTo(.rgbs, gpa);
        defer rgb_pxs.deinit(gpa);
        // rgbs -> grays
        const gray_pxs = try rgb_pxs.convertTo(.grays, gpa);
        defer gray_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const gray_act: u8 = @bitCast(gray_pxs.grays[i]);
            const gray_exp: u8 = data[i];
            try std.testing.expectEqualDeep(gray_exp, gray_act);
        }
        // rgbs -> rgbas
        const rgba_pxs = try rgb_pxs.convertTo(.rgbas, gpa);
        defer rgba_pxs.deinit(gpa);
        for (0..data.len) |i| {
            try std.testing.expect( //
                rgba_pxs.rgbas[i].eql(RGBA{
                    .red = data[i],
                    .green = data[i],
                    .blue = data[i],
                }));
        }
    }

    { // rgbas
        const rgba_pxs = try base_pxs.convertTo(.rgbas, gpa);
        defer rgba_pxs.deinit(gpa);
        // rgbas -> grays
        const gray_pxs = try rgba_pxs.convertTo(.grays, gpa);
        defer gray_pxs.deinit(gpa);
        for (0..data.len) |i| {
            const gray_act: u8 = @bitCast(gray_pxs.grays[i]);
            const gray_exp = data[i];
            try std.testing.expectEqual(gray_exp, gray_act);
        }
        // rgbas -> rgbs
        const rgb_pxs = try rgba_pxs.convertTo(.rgbs, gpa);
        defer rgb_pxs.deinit(gpa);
        for (0..data.len) |i| {
            try std.testing.expect(rgb_pxs.rgbs[i].eql(RGB{
                .red = data[i],
                .green = data[i],
                .blue = data[i],
            }));
        }
    }
}
