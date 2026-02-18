pub const DecodeError = error{
    InvalidSignature,
    InvalidHeader,
    UnsupportedBitsPerPixel,
    UnsupportedCompression,
    UnexpectedEndOfData,
    InvalidDimensions,
};

pub const Compression = enum(u32) {
    none = 0,
    rle8 = 1,
    rle4 = 2,
    bitfields = 3,
};
