//! What a decoder learns from a file's header, before touching pixel data.
//! Every codec exposes `info(data) !Info`, so callers can size (or reuse)
//! the destination buffer before calling `decodeInto`.
const std = @import("std");
const vk = @import("Vulkan");
const PixelTag = @import("Colors/pixels.zig").PixelTag;

width: u32,
height: u32,
tag: PixelTag,
fmt: vk.Format,

pub fn nPixels(self: @This()) !usize {
    const n, const overflow = @mulWithOverflow(@as(usize, self.width), @as(usize, self.height));
    if (overflow != 0 or n == 0) return error.InvalidDimensions;
    return n;
}

/// Bytes needed to hold the decoded pixels.
pub fn byteLen(self: @This()) !usize {
    const n, const overflow = @mulWithOverflow(try self.nPixels(), @as(usize, self.tag.bytesPerPixel()));
    if (overflow != 0) return error.InvalidDimensions;
    return n;
}

pub fn eqlShape(a: @This(), b: @This()) bool {
    return a.width == b.width and a.height == b.height and a.tag == b.tag;
}

/// True for sRGB-encoded formats (`*_srgb`, `*_srgb_block`, `*_srgb_pack32`, ...).
/// `vk.Format` is non-exhaustive: a value this vk.zig has no name for is not sRGB.
pub fn isSrgb(fmt: vk.Format) bool {
    const name = std.enums.tagName(vk.Format, fmt) orelse return false;
    return std.mem.indexOf(u8, name, "srgb") != null;
}

/// Default Vulkan format for a pixel layout.
pub fn fmtFor(tag: PixelTag, srgb: bool) vk.Format {
    return switch (tag) {
        .g => if (srgb) .r8_srgb else .r8_unorm,
        .ga => if (srgb) .r8g8_srgb else .r8g8_unorm,
        .rgb => if (srgb) .r8g8b8_srgb else .r8g8b8_unorm,
        .bgr => if (srgb) .b8g8r8_srgb else .b8g8r8_unorm,
        .rgba => if (srgb) .r8g8b8a8_srgb else .r8g8b8a8_unorm,
        .bgra => if (srgb) .b8g8r8a8_srgb else .b8g8r8a8_unorm,
        // linear: Vulkan has no 16-bit sRGB format
        .g16 => .r16_unorm,
        // no packed 8-bit YCbCr format in core Vulkan; convert before upload
        .ycbcr, .ycbcra => .undefined,
    };
}
