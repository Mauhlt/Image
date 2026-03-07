const std = @import("std");
const testing = std.testing;

/// Goal:
/// 1. Create an intrusive interface to load images
/// 2. Types of supported images:
///    - width, height, depth
///    - u8
///    - variable image data + variable images
/// 3. TODO:
///     - depth
///     - u16, i8, i16, f16, f32, f64
///     - const image data + const images
pub fn ColorStruct(comptime T: type) type {
    return struct {
        r: T,
        g: T,
        b: T,
        a: T,
    };
}

const BitTypes = enum {
    // rgb,
    rgba,
};

/// Image Struct:
/// T: must be an integer or float
pub fn ImageStruct() type {
    return struct {
        width: u32,
        height: u32,
        data: []RGBA,
    };
}

/// Common Structs
pub const RGBA = ColorStruct(u8);
pub const Image2D = ImageStruct(false);
