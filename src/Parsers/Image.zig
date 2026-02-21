const std = @import("std");
const testing = std.testing;

/// Goal:
/// 1. Create a universal fn to create different types of images
/// 2. Types of supported images:
///    - width, height, depth
///    - u8, u16, i8, i16, f16, f32, f64
///    - const or variable images
///    - can compute properties:
///      - getWidth, getHeight, getDepth
pub fn ColorStruct(comptime T: type) type {
    return struct {
        r: T,
        g: T,
        b: T,
        a: T,
    };
}

/// fn will create custom images
pub fn ImageStruct(
    comptime T: type,
    comptime is_const: bool,
    comptime has_depth: bool,
) type {
    switch (@typeInfo(T)) {
        .int, .float => {},
        else => @compileError("Fn only accepts integers or floats."),
    }

    // default = 2, may have depth 3,
    const len = 2 + @intFromBool(has_depth);
    var struct_fields: [len + 2]std.builtin.Type.StructField = undefined;

    // dimensions
    const field_names = [_][]const u8{ "width", "height", "depth" };
    for (0..len) |i| {
        struct_fields[i] = .{
            .alignment = 4,
            .default_value_ptr = 0,
            .is_comptime = false,
            .name = field_names[i],
            .type = u32,
        };
    }

    // bit depth
    struct_fields[len] = .{
        .alignment = null,
        .default_value_ptr = null,
        .is_comptime = false,
        .name = "bit_depth",
        .type = u8,
    };

    // Data
    const Color = ColorStruct(T);
    struct_fields[len + 1] = .{
        .alignment = null,
        .default_value_ptr = null,
        .is_comptime = false,
        .name = "data",
        .type = switch (is_const) {
            true => []const Color,
            false => []Color,
        },
    };

    return @Type(std.builtin.Type.Struct{
        .backing_integer = null,
        .decls = &.{},
        .fields = &struct_fields,
        .is_tuple = false,
        .layout = .auto,
    });
}

/// Common Structs
pub const Image2D = ImageStruct(u8, false, false);
pub const ConstImage2D = ImageStruct(u8, true, false);
// pub const Image3D = ImageStruct(u8, false, true);
// pub const ConstImage3D = ImageStruct(u8, true, false);
