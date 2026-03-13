const RGB = @import("RGB.zig");
const RGBA = @import("RGBA.zig");
pub const BitType = union(enum) {
    rgb: [*]RGB,
    rgba: [*]RGBA,
};
