pub const Decode = error{
    ChunkIsNotHeader,
    InvalidBitsPerPixel,
    InvalidChunkType,
    InvalidCompression,
    InvalidDataLength,
    InvalidFormat,
    InvalidHeader,
    InvalidHeaderLength,
    InvalidHeaderSize,
    InvalidImageDimensions,
    InvalidImportantColors,
    InvalidNumberOfColors,
    UnsupportedBitsPerPixel,
    UnsupportedCompression,
    UnexpectedEndOfData,
    UnsupportedNumberOfChannels,
    UnexpectedSignature,
};

pub const Encode = error{
    InvalidImageDimensions,
};
