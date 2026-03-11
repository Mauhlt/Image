pub const Decode = error{
    UnsupportedBitsPerPixel,
    UnexpectedSignature,
    UnexpectedEndOfData,
    UnsupportedCompression,
    UnsupportedNumChannels,
    InvalidChunkType,
    InvalidHeaderLength,
    InvalidHeader,
    InvalidDimensions,
    ChunkIsNotHeader,
};

pub const Encode = error{};
