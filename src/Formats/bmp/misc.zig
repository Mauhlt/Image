pub const BitsPerPixel = enum(u8) {
    monochrome = 1,
    bit_4_pallet = 4,
    bit_8_pallet = 8,
    rgb_16 = 16,
    rgb_24 = 24,
    rgba = 32,
};

pub const Compression = enum(u32) {
    none = 0,
    rle8 = 1,
    rle4 = 2,
};

pub const SIG: []const u8 = "BM";
