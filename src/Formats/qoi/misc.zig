pub const SIG: []const u8 = "qoif";
pub const Colorspace = enum(u8) {
    srgb = 0, // linear alpha
    linear = 1,
};
pub const Channel = enum(u8) {
    rgb = 3,
    rgba = 4,
};
