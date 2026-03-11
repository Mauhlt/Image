pub const Decode = error{
    InvalidNumOfColors,
    InvalidImportantColors,
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
