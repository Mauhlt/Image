const std = @import("std");
const testing = std.testing;

/// Goal:
/// 1. Create an intrusive interface to load images
/// 2. Types of supported images:
///    - width, height
///    - u8
///    - rgb, rgba
///    - srgb, linear
///    - variable image data + variable images
/// 3. TODO:
///     - depth
///     - u16, i8, i16, f16, f32, f64
///     - const image data + const images
pub fn ColorStruct(comptime bit_type: BitType) type {
    return switch (bit_type) {
        .rgb => struct { r: u8, g: u8, b: u8 },
        .rgba => struct { r: u8, g: u8, b: u8, a: u8 },
    };
}

const BitType = enum(u8) {
    rgb,
    rgba,
};

const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

/// Image Struct:
/// T: must be an integer or float
pub fn ImageStruct(comptime bit_type: BitType) type {
    return switch (bit_type) {
        .rgb => struct {
            width: u32 = 0,
            height: u32 = 0,
            colorspace: Colorspace = .srgb,
            data: []RGB = undefined,
        },
        .rgba => struct {
            width: u32 = 0,
            height: u32 = 0,
            colorspace: Colorspace = .srgb,
            data: []RGBA = undefined,
        },
    };
}

/// Common Structs
pub const RGB = ColorStruct(.rgb);
pub const RGBA = ColorStruct(.rgba);
pub const Image2DRGB = ImageStruct(.rgb);
pub const Image2DRGBA = ImageStruct(.rgba);
