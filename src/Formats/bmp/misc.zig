pub const BitsPerPixel = enum(u16) {
    bit_1_palette = 1,
    /// Windows CE only
    bit_2_palette = 2,
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
    /// BI_ALPHABITFIELDS (Windows CE): like bitfields, with a 4th (alpha) mask
    alphabitfields = 6,
};

pub const SIG: []const u8 = "BM";
pub const FILE_HDR_SIZE = 14;
/// OS/2 1.x BITMAPCOREHEADER: 16-bit dimensions, 3-byte palette entries
pub const CORE_HDR_SIZE = 12;
pub const INFO_HDR_SIZE = 40;
pub const V4_HDR_SIZE = 108;

/// pads every row to next 4-byte boundary
pub fn strideOf(row_bytes: usize) usize {
    return (row_bytes + 3) & ~@as(usize, 3);
}
