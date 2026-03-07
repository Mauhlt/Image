pub const DecodeError = error{
    UnexpectedSignature,
    InvalidChunkType,
    ChunkIsNotHeader,
    InvalidHeaderLength,
};
