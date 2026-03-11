pub const Decode = error{
    InvalidHeaderSize,
    InvalidBitsPerPixel,
    UnsupportedBitsPerPixel,
    UnexpectedSignature,
    UnexpectedEndOfData,
    InvalidCompression,
    UnsupportedCompression,
    UnsupportedNumChannels,
    InvalidChunkType,
    InvalidHeaderLength,
    InvalidHeader,
    InvalidDimensions,
    ChunkIsNotHeader,
};

pub const Encode = error{};
