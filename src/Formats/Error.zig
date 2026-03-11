pub const DecodeError = error{
    UnsupportedBitsPerPixel,
    UnexpectedSignature,
    InvalidChunkType,
    ChunkIsNotHeader,
    InvalidHeaderLength,
};

pub const EncodeError = error{};
