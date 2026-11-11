pub const BitsPerPixel = enum(u16) {
    bit_1_palette = 1,
    bit_4_palette = 4,
    bit_8_palette = 8,
    rgb_16 = 16,
    rgb_24 = 24,
    rgba_32 = 32,
};

pub const Compression = enum(u32) {
    none = 0,
    rle8 = 1,
    rle4 = 2,
    bitfields = 3,
};

pub const SIG: []const u8 = "BM";
pub const FILE_HDR_SIZE = 14;
pub const INFO_HDR_SIZE = 40;

/// pads every row to next 4-byte boundary
pub fn strideOf(row_bytes: usize) usize {
    return (row_bytes + 3) & ~@as(usize, 3);
}
