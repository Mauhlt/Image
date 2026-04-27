const MultiArrayList = @import("std").MultiArrayList;

pub const GRAY = struct {
    l: u8,
};

pub const RGB_16 = struct {
    r: u4 = 0,
    g: u4 = 0,
    b: u4 = 0,
    a: u4 = 15,
};
pub const RGBS_16 = MultiArrayList(RGB_16);

pub const RGB_24 = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};
pub const RGBS_24 = MultiArrayList(RGB_24);

pub const RGBA = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0xFF,
};
pub const RGBAS = MultiArrayList(RGBA);
