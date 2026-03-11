pub const Decode = error{
    UnsupportedBitsPerPixel,
    UnexpectedSignature,
    UnexpectedEndOfData,
    InvalidChunkType,
    InvalidHeaderLength,
    ChunkIsNotHeader,
};

pub const Encode = error{};
