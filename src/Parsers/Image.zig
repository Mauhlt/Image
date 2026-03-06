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

const BitTypes = enum {
    rgb,
    rgba,
};

/// Image Struct:
/// T: must be an integer or float
/// is_const: defines whether data can be modified,
pub fn ImageStruct(
    // comptime T: type,
    comptime is_const: bool,
) type {
    // switch (@typeInfo(T)) {
    //     .int, .float => {},
    //     else => @compileError("Fn only accepts integers or floats."),
    // }
    return struct {
        width: u32,
        height: u32,
        data: switch (is_const) {
            true => []const RGBA,
            false => []RGBA,
        },
    };
}

/// Common Structs
const RGBA = ColorStruct(u8);
pub const Image2D = ImageStruct(false);
pub const ConstImage2D = ImageStruct(true);
