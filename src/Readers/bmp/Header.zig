const misc = @import("misc.zig");

const Header = struct {
    width: u32,
    height: u32,
    bits_per_pixel: u16,
    compression: misc.Compression,
    top_down: bool,
};
