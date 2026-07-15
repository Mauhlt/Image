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

/// pads every row to next 4-byte boundary
pub fn strideOf(row_bytes: u32) u32 {
    return (row_bytes + 3) & ~@as(u32, 3);
}
