//! DDS_HEADER (124 bytes after the "DDS " magic) + optional DDS_HEADER_DXT10 (20 bytes).
const std = @import("std");
const vk = @import("Vulkan");
const Error = @import("../error.zig").Error;

pub const MAGIC = "DDS ";
pub const HEADER_SIZE = 124;
pub const DX10_SIZE = 20;

pub const Flags = struct {
    pub const caps = 0x1;
    pub const height = 0x2;
    pub const width = 0x4;
    pub const pixel_format = 0x1000;
    pub const mip_count = 0x20000;
    pub const linear_size = 0x80000;
};
pub const PF_FOURCC = 0x4;
pub const PF_RGB = 0x40;
pub const PF_ALPHA_PIXELS = 0x1;
pub const PF_LUMINANCE = 0x20000;
pub const CAPS_COMPLEX = 0x8;
pub const CAPS_TEXTURE = 0x1000;
pub const CAPS_MIPMAP = 0x400000;
pub const CAPS2_CUBEMAP = 0x200;
pub const CAPS2_CUBEMAP_ALL = 0xFE00;
pub const MISC_TEXTURECUBE = 0x4;

width: u32,
height: u32,
levels: u32,
layers: u32,
faces: u32,
fmt: vk.Format,
data_offset: usize,
/// file holds BC2 blocks; the Vulkan bindings lack bc2_*, so the loader decodes to RGBA8
bc2: bool = false,

fn fourcc(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .little);
}

pub fn dxgiToVk(dxgi: u32) ?vk.Format {
    return switch (dxgi) {
        28 => .r8g8b8a8_unorm,
        29 => .r8g8b8a8_srgb,
        49 => .r8g8_unorm,
        61 => .r8_unorm,
        70, 71 => .bc1_rgba_unorm_block,
        72 => .bc1_rgba_srgb_block,
        76, 77 => .bc3_unorm_block,
        78 => .bc3_srgb_block,
        79, 80 => .bc4_unorm_block,
        81 => .bc4_snorm_block,
        82, 83 => .bc5_unorm_block,
        84 => .bc5_snorm_block,
        94, 95 => .bc6h_ufloat_block,
        96 => .bc6h_sfloat_block,
        97, 98 => .bc7_unorm_block,
        99 => .bc7_srgb_block,
        87 => .b8g8r8a8_unorm,
        91 => .b8g8r8a8_srgb,
        else => null,
    };
}

pub fn vkToDxgi(fmt: vk.Format) ?u32 {
    return switch (fmt) {
        .r8g8b8a8_unorm => 28,
        .r8g8b8a8_srgb => 29,
        .r8g8_unorm => 49,
        .r8_unorm => 61,
        .bc1_rgb_unorm_block, .bc1_rgba_unorm_block => 71,
        .bc1_rgb_srgb_block, .bc1_rgba_srgb_block => 72,
        .bc3_unorm_block => 77,
        .bc3_srgb_block => 78,
        .bc4_unorm_block => 80,
        .bc4_snorm_block => 81,
        .bc5_unorm_block => 83,
        .bc5_snorm_block => 84,
        .bc6h_ufloat_block => 95,
        .bc6h_sfloat_block => 96,
        .bc7_unorm_block => 98,
        .bc7_srgb_block => 99,
        .b8g8r8a8_unorm => 87,
        .b8g8r8a8_srgb => 91,
        else => null,
    };
}

pub fn decode(data: []const u8) Error!@This() {
    if (data.len < 4 + HEADER_SIZE or !std.mem.eql(u8, data[0..4], MAGIC)) return Error.UnexpectedSignature;
    const h = data[4..][0..HEADER_SIZE];
    if (std.mem.readInt(u32, h[0..4], .little) != HEADER_SIZE) return Error.InvalidHeaderLen;
    const height = std.mem.readInt(u32, h[8..12], .little);
    const width = std.mem.readInt(u32, h[12..16], .little);
    const depth = std.mem.readInt(u32, h[20..24], .little);
    const mips = std.mem.readInt(u32, h[24..28], .little);
    const pf = h[72..][0..32];
    const pf_flags = std.mem.readInt(u32, pf[4..8], .little);
    const four = pf[8..12];
    const bit_count = std.mem.readInt(u32, pf[12..16], .little);
    const r_mask = std.mem.readInt(u32, pf[16..20], .little);
    const caps2 = std.mem.readInt(u32, h[108..112], .little);
    if (width == 0 or height == 0) return Error.InvalidDimensions;
    if (depth > 1) return Error.UnsupportedFeature; // volume textures

    var hdr: @This() = .{
        .width = width,
        .height = height,
        .levels = @max(1, mips),
        .layers = 1,
        .faces = if (caps2 & CAPS2_CUBEMAP != 0) 6 else 1,
        .fmt = .undefined,
        .data_offset = 4 + HEADER_SIZE,
    };

    if (pf_flags & PF_FOURCC != 0) {
        const cc = fourcc(four);
        if (cc == fourcc("DX10")) {
            if (data.len < 4 + HEADER_SIZE + DX10_SIZE) return Error.UnexpectedEndOfData;
            const x = data[4 + HEADER_SIZE ..][0..DX10_SIZE];
            const dxgi = std.mem.readInt(u32, x[0..4], .little);
            if (dxgi >= 73 and dxgi <= 75) {
                hdr.bc2 = true;
                hdr.fmt = if (dxgi == 75) .r8g8b8a8_srgb else .r8g8b8a8_unorm;
            } else hdr.fmt = dxgiToVk(dxgi) orelse return Error.UnsupportedColorspace;
            const dim = std.mem.readInt(u32, x[4..8], .little);
            if (dim != 3) return Error.UnsupportedFeature; // only TEXTURE2D
            const misc = std.mem.readInt(u32, x[8..12], .little);
            if (misc & MISC_TEXTURECUBE != 0) hdr.faces = 6;
            hdr.layers = @max(1, std.mem.readInt(u32, x[12..16], .little));
            hdr.data_offset += DX10_SIZE;
        } else if (cc == fourcc("DXT1")) {
            hdr.fmt = .bc1_rgba_unorm_block;
        } else if (cc == fourcc("DXT2") or cc == fourcc("DXT3")) {
            hdr.bc2 = true;
            hdr.fmt = .r8g8b8a8_unorm;
        } else if (cc == fourcc("DXT4") or cc == fourcc("DXT5")) {
            hdr.fmt = .bc3_unorm_block;
        } else if (cc == fourcc("ATI1") or cc == fourcc("BC4U")) {
            hdr.fmt = .bc4_unorm_block;
        } else if (cc == fourcc("BC4S")) {
            hdr.fmt = .bc4_snorm_block;
        } else if (cc == fourcc("ATI2") or cc == fourcc("BC5U")) {
            hdr.fmt = .bc5_unorm_block;
        } else if (cc == fourcc("BC5S")) {
            hdr.fmt = .bc5_snorm_block;
        } else return Error.UnsupportedColorspace;
    } else if (pf_flags & PF_RGB != 0 and bit_count == 32) {
        hdr.fmt = switch (r_mask) {
            0x000000FF => .r8g8b8a8_unorm,
            0x00FF0000 => .b8g8r8a8_unorm,
            else => return Error.UnsupportedColorspace,
        };
    } else if (pf_flags & PF_LUMINANCE != 0 and bit_count == 8) {
        hdr.fmt = .r8_unorm;
    } else return Error.UnsupportedColorspace;
    return hdr;
}
