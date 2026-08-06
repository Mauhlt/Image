const std = @import("std");

const Position = @import("position.zig");

const GrayOrder = @import("pixel_format.zig").GrayOrder;
const GrayAlphaOrder = @import("pixel_format.zig").GrayAlphaOrder;
const RgbOrder = @import("pixel_format.zig").RgbOrder;
const RgbaOrder = @import("pixel_format.zig").RgbaOrder;

const GRAY = @import("pixel_format.zig").GRAY;
const GRAY_ALPHA = @import("pixel_format.zig").GRAY_ALPHA;
const RGB = @import("pixel_format.zig").RGB;
const BGR = @import("pixel_format.zig").BGR;
const RGBA = @import("pixel_format.zig").RGBA;
const BGRA = @import("pixel_format.zig").BGRA;

const VEC_LEN = std.simd.suggestVectorLength(f32) orelse 16;
const VF32 = @Vector(VEC_LEN, f32);
const VU8 = @Vector(VEC_LEN, u8);
const VU64 = @Vector(VEC_LEN, usize);
const SEL = std.simd.iota(usize, VEC_LEN);
const MUL2: VU64 = @splat(2);
const MUL3: VU64 = @splat(3);
const MUL4: VU64 = @splat(4);
const ADD1: VU64 = @splat(1);
const ADD2: VU64 = @splat(2);
const ADD3: VU64 = @splat(3);

const PixelTag = enum(u8) {
    grays,
    gray_alphas,
    rgbs,
    bgrs,
    rgbas,
    bgras,

    fn modCheck(self: PixelTag, data: []const u8) !void {
        return if (@mod(data.len, self.alignOf()) != 0) error.InvalidDataLength else {};
    }

    fn alignOf(self: PixelTag) usize {
        return switch (self) {
            .grays => 1,
            .gray_alphas => 2,
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

const DataTag: type = MergeEnums(&.{
    GrayOrder,
    GrayAlphaOrder,
    RgbOrder,
    RgbaOrder,
}) catch unreachable;

pub const Pixels = union(PixelTag) {
    grays: []GRAY,
    gray_alphas: []GRAY_ALPHA,
    rgbs: []RGB,
    bgrs: []BGR,
    rgbas: []RGBA,
    bgras: []BGRA,

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

    // Assumes data is:
    //   - correct alignment (u24 vs u32)
    pub fn initOrder(
        gpa: std.mem.Allocator,
        data: []const u8,
        data_order: DataTag,
        pixel_order: PixelTag,
    ) !@This() {
        if (data.len == 0) return error.InvalidDataLength;
        try pixel_order.modCheck(data);
        const n_bytes_per_pixel = pixel_order.alignOf();
        const len = data.len / n_bytes_per_pixel;
        switch (pixel_order) {
            inline else => {
                const DstElem = std.meta.Elem(@FieldType(Pixels, @tagName(pixel_order)));
                const slice = try gpa.alloc(DstElem, len);
                errdefer gpa.free(slice);
                for (0..len) |i| {
                    slice[i] = .initOrder(
                        data[i * n_bytes_per_pixel ..][0..n_bytes_per_pixel],
                        @enumFromInt(@intFromEnum(data_order)),
                    );
                }
            },
        }
    }

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
                    .gray_alphas => "toGrayAlpha",
                    .rgbs => "toRgb",
                    .rgbas => "toRgba",
                    .bgrs => "toBgr",
                    .bgras => "toBgras",
                };
                const dst = try gpa.alloc(DstElem, len);
                errdefer gpa.free(dst);
                for (src, dst) |s, *d| d.* = @field(@TypeOf(s), method)(s);
                return @unionInit(Pixels, @tagName(other_tag), dst);
            }
        }
    }

    pub fn crop(
        self: @This(),
        gpa: std.mem.Allocator,
        box: [2]Position,
    ) !@This() {
        const min_row = @min(@min(box[0].row, box[1].row), self.height - 1);
        const max_row = @min(@max(box[0].row, box[1].row), self.height - 1);

        const min_col = @min(@min(box[0].col, box[1].col), self.width - 1);
        const max_col = @min(@max(box[0].col, box[1].col), self.width - 1);

        const height: u32 = @truncate(max_row - min_row);
        const width: u32 = @truncate(max_col - min_col);
        if (height == self.height and width == self.width) return self.dupe(gpa);

        const n_pixels = width * height;

        switch (self) {
            inline else => |pixels| {
                var new_pixels = try gpa.alloc(@TypeOf(pixels), n_pixels);
                errdefer gpa.free(new_pixels);
                for (0..height) |i| {
                    @memcpy(
                        new_pixels[i * width ..][0..width],
                        pixels[min_row + i * self.width][0..width],
                    );
                }
                return .{
                    .width = width,
                    .height = height,
                    .fmt = self.fmt,
                    .pixels = new_pixels,
                    .order = self.order,
                };
            },
        }
    }

    pub fn luminance(self: @This(), gpa: std.mem.Allocator) ![]f32 {
        // uses memcpy/vectors for faster speed
        const len = self.length();
        var lum = try gpa.alloc(f32, len);
        errdefer gpa.free(lum);
        switch (self) {
            .grays => |grays| {
                const data: []const u8 = @ptrCast(grays);
                var i: usize = 0;
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    lum[i..][0..VEC_LEN].* = @floatFromInt(@as(VU8, data[i..][0..VEC_LEN].*));
                }
                while (i < data.len) : (i += 1) {
                    lum[i] = grays[i].luminance();
                }
            },
            .gray_alphas => |gray_alphas| {
                const data: []const u8 = @ptrCast(gray_alphas);
                var i: usize = 0;
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    lum[i..][0..VEC_LEN].* = @floatFromInt(@as(VU8, data[i * 2 ..][SEL * MUL2].*));
                }
                while (i < len) : (i += 1) {
                    lum[i] = gray_alphas[i].luminance();
                }
            },
            .rgbs => |rgbs| {
                const data: []const u8 = @ptrCast(rgbs);
                var reds: VF32 = undefined;
                var greens: VF32 = undefined;
                var blues: VF32 = undefined;
                var i: usize = 0;
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    reds = @floatFromInt(@as(VU8, data[i..][SEL * MUL3].*));
                    greens = @floatFromInt(@as(VU8, data[i..][SEL * MUL3 + ADD1].*));
                    blues = @floatFromInt(@as(VU8, data[i..][SEL * MUL3 + ADD2].*));
                    lum[i..][0..VEC_LEN].* = @as(VF32, @splat(0.299)) * reds + //
                        @as(VF32, @splat(0.587)) * greens + //
                        @as(VF32, @splat(0.144)) * blues;
                }
                while (i < len) : (i += 1) {
                    lum[i] = rgbs[i].luminance();
                }
            },
            .bgrs => |bgrs| {
                const data: []const u8 = @ptrCast(bgrs);
                var blues: VF32 = undefined;
                var greens: VF32 = undefined;
                var reds: VF32 = undefined;
                var i: usize = 0;
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    blues = @floatFromInt(@as(VU8, data[i..][SEL * MUL3].*));
                    greens = @floatFromInt(@as(VU8, data[i..][SEL * MUL3 + ADD1].*));
                    reds = @floatFromInt(@as(VU8, data[i..][SEL * MUL3 + ADD2].*));
                    lum[i..][0..VEC_LEN].* = @as(VF32, @splat(0.144)) * blues + //
                        @as(VF32, @splat(0.587)) * greens + //
                        @as(VF32, @splat(0.299)) * reds;
                }
                while (i < len) : (i += 1) {
                    lum[i] = bgrs[i].luminance();
                }
            },
            .rgbas => |rgbas| {
                const data: []const u8 = @ptrCast(rgbas);
                var reds: VF32 = undefined;
                var greens: VF32 = undefined;
                var blues: VF32 = undefined;
                var i: usize = 0;
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    reds = @floatFromInt(@as(VU8, data[i..][SEL * MUL4].*));
                    greens = @floatFromInt(@as(VU8, data[i..][SEL * MUL4 + ADD1].*));
                    blues = @floatFromInt(@as(VU8, data[i..][SEL * MUL4 + ADD2].*));
                    lum[i..][0..VEC_LEN].* = @as(VF32, @splat(0.299)) * reds + //
                        @as(VF32, @splat(0.587)) * greens + //
                        @as(VF32, @splat(0.144)) * blues;
                }
                while (i < len) : (i += 1) {
                    lum[i] = rgbas[i].luminance();
                }
            },
            .bgras => |bgras| {
                const data: []const u8 = @ptrCast(bgras);
                var blues: VF32 = undefined;
                var greens: VF32 = undefined;
                var reds: VF32 = undefined;
                var i: usize = 0;
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    blues = @floatFromInt(@as(VU8, data[i..][SEL * MUL4].*));
                    greens = @floatFromInt(@as(VU8, data[i..][SEL * MUL4 + ADD1].*));
                    reds = @floatFromInt(@as(VU8, data[i..][SEL * MUL4 + ADD2].*));
                    lum[i..][0..VEC_LEN].* = @as(VF32, @splat(0.144)) * blues + //
                        @as(VF32, @splat(0.587)) * greens + //
                        @as(VF32, @splat(0.299)) * reds;
                }
                while (i < len) : (i += 1) {
                    lum[i] = bgras[i].luminance();
                }
            },
        }
        return lum;
    }

    pub fn blueChrominance(self: @This(), gpa: std.mem.Allocator) ![]f32 {
        const len = self.length();
        var cb = try gpa.alloc(f32, len);
        errdefer gpa.free(cb);
        var i: usize = 0;
        switch (self) {
            .grays => |grays| {
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    const gs: VF32 = @floatFromInt(@as(VU8, grays[i..][0..VEC_LEN].*));
                    cb[i..][0..VEC_LEN].* = @as(VF32, @splat(-0.1687)) * gs + //
                        @as(VF32, @splat(-0.3313)) * gs + //
                        @as(VF32, @splat(0.5)) * gs + //
                        @as(VF32, @splat(128));
                }
                while (i < len) : (i += 1) {
                    cb[i] = grays[i].blueChrominance();
                }
            },
            .gray_alphas => |gray_alphas| {
                const data: []const u8 = @ptrCast(gray_alphas);
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    const gs: VF32 = @floatFromInt(@as(VU8, data[i..][SEL * MUL2].*));
                    cb[i..][0..VEC_LEN].* = @as(VF32, @splat(-0.1687)) * gs + //
                        @as(VF32, @splat(-0.3313)) * gs + //
                        @as(VF32, @splat(0.5)) * gs + //
                        @as(VF32, @splat(128));
                }
                while (i < len) : (i += 1) {
                    cb[i] = gray_alphas[i].blueChrominance();
                }
            },
            .rgbs => |rgbs| {
                const data: []const u8 = @ptrCast(rgbs);
                while (i + VEC_LEN < len) : (i += VEC_LEN) {}
            },
            .bgrs => |bgrs| {
                const data: []const u8 = @ptrCast(bgrs);
                while (i + VEC_LEN < len) : (i += VEC_LEN) {}
            },
            .rgbas => |rgbas| {
                const data: []const u8 = @ptrCast(rgbas);
                while (i + VEC_LEN < len) : (i += VEC_LEN) {}
            },
            .bgras => |bgras| {
                const data: []const u8 = @ptrCast(bgras);
                while (i + VEC_LEN < len) : (i += VEC_LEN) {}
            },
        }
        return cb;
    }

    pub fn redChrominance(self: @This(), gpa: std.mem.Allocator) ![]f32 {
        const len = self.length();
        var cr = try gpa.alloc(f32, len);
        errdefer gpa.free(cr);
        var i: usize = 0;
        switch (self) {
            .grays => |grays| {
                while (i + VEC_LEN < len) : (i += VEC_LEN) {
                    const gs: VF32 = @floatFromInt(@as(VU8, grays[i..][0..VEC_LEN].*));
                    cr[i..][0..VEC_LEN].* = @as(VF32, @splat(-0.1687)) * gs + //
                        @as(VF32, @splat(-0.3313)) * gs + //
                        @as(VF32, @splat(0.5)) * gs + //
                        @as(VF32, @splat(128));
                }
            },
            .gray_alphas => |gray_alphas| {},
            .rgbs => |rgbs| {},
            .bgrs => |bgrs| {},
            .rgbas => |rgbas| {},
            .bgras => |bgras| {},
        }
        return cr;
    }
};

test "Pixels" {
    @setEvalBranchQuota(10_000);
    const da_fields = std.meta.fields(DataTag);
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
    // const da: DataTag = .g;
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
