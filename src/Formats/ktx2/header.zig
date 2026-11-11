//! KTX 2.0 header, index and level index. https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html
const std = @import("std");
const vk = @import("Vulkan");
const Error = @import("../error.zig").Error;

pub const IDENTIFIER = [12]u8{ 0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, '\r', '\n', 0x1A, '\n' };
pub const HEADER_SIZE = 80;
pub const LEVEL_ENTRY_SIZE = 24;

pub const Supercompression = enum(u32) {
    none = 0,
    basis_lz = 1,
    zstd = 2,
    zlib = 3,
    _,
};

pub const Level = struct {
    offset: u64,
    len: u64,
    uncompressed_len: u64,
};

vk_format: u32,
type_size: u32,
width: u32,
height: u32,
depth: u32,
layers: u32,
faces: u32,
levels: u32,
supercompression: Supercompression,
dfd_offset: u32 = 0,
dfd_len: u32 = 0,
kvd_offset: u32 = 0,
kvd_len: u32 = 0,
sgd_offset: u64 = 0,
sgd_len: u64 = 0,

pub fn decode(data: []const u8) Error!@This() {
    if (data.len < HEADER_SIZE or !std.mem.eql(u8, data[0..12], &IDENTIFIER)) return Error.UnexpectedSignature;
    const r = struct {
        fn u(d: []const u8, off: usize) u32 {
            return std.mem.readInt(u32, d[off..][0..4], .little);
        }
    }.u;
    const hdr: @This() = .{
        .vk_format = r(data, 12),
        .type_size = r(data, 16),
        .width = r(data, 20),
        .height = r(data, 24),
        .depth = r(data, 28),
        .layers = r(data, 32),
        .faces = r(data, 36),
        .levels = r(data, 40),
        .supercompression = @enumFromInt(r(data, 44)),
        .dfd_offset = r(data, 48),
        .dfd_len = r(data, 52),
        .kvd_offset = r(data, 56),
        .kvd_len = r(data, 60),
        .sgd_offset = std.mem.readInt(u64, data[64..72], .little),
        .sgd_len = std.mem.readInt(u64, data[72..80], .little),
    };
    if (hdr.width == 0) return Error.InvalidDimensions;
    if (hdr.depth > 1) return Error.UnsupportedFeature; // 3D textures
    if (hdr.faces != 1 and hdr.faces != 6) return Error.InvalidHeader;
    if (data.len < HEADER_SIZE + @as(usize, @max(1, hdr.levels)) * LEVEL_ENTRY_SIZE) return Error.UnexpectedEndOfData;
    return hdr;
}

pub fn level(data: []const u8, i: usize) Level {
    const e = data[HEADER_SIZE + i * LEVEL_ENTRY_SIZE ..][0..LEVEL_ENTRY_SIZE];
    return .{
        .offset = std.mem.readInt(u64, e[0..8], .little),
        .len = std.mem.readInt(u64, e[8..16], .little),
        .uncompressed_len = std.mem.readInt(u64, e[16..24], .little),
    };
}

// ── Data Format Descriptor (required by the spec; we only write it) ──

const Sample = struct { offset: u16, bits: u8, channel: u8, upper: u32 };

/// Basic DFD block for the formats this library writes.
pub fn writeDfd(fmt: vk.Format, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const srgb = std.mem.indexOf(u8, @tagName(fmt), "srgb") != null;
    var model: u8 = 1; // RGBSDA
    var block: [4]u8 = .{ 0, 0, 0, 0 }; // dimension - 1
    var bytes: u8 = 4;
    var samples_buf: [4]Sample = undefined;
    var samples: []const Sample = undefined;
    switch (fmt) {
        .r8g8b8a8_unorm, .r8g8b8a8_srgb => {
            samples_buf = .{
                .{ .offset = 0, .bits = 7, .channel = 0, .upper = 255 },
                .{ .offset = 8, .bits = 7, .channel = 1, .upper = 255 },
                .{ .offset = 16, .bits = 7, .channel = 2, .upper = 255 },
                .{ .offset = 24, .bits = 7, .channel = 15 | @as(u8, if (srgb) 0x10 else 0), .upper = 255 },
            };
            samples = samples_buf[0..4];
        },
        else => {
            block = .{ 3, 3, 0, 0 };
            const full: u32 = 0xFFFFFFFF;
            switch (fmt) {
                .bc1_rgba_unorm_block, .bc1_rgba_srgb_block, .bc1_rgb_unorm_block, .bc1_rgb_srgb_block => {
                    model = 128;
                    bytes = 8;
                    samples_buf[0] = .{ .offset = 0, .bits = 63, .channel = 0, .upper = full };
                    samples = samples_buf[0..1];
                },
                .bc3_unorm_block, .bc3_srgb_block => {
                    model = 130;
                    bytes = 16;
                    samples_buf[0] = .{ .offset = 0, .bits = 63, .channel = 15 | @as(u8, if (srgb) 0x10 else 0), .upper = full };
                    samples_buf[1] = .{ .offset = 64, .bits = 63, .channel = 0, .upper = full };
                    samples = samples_buf[0..2];
                },
                .bc4_unorm_block => {
                    model = 131;
                    bytes = 8;
                    samples_buf[0] = .{ .offset = 0, .bits = 63, .channel = 0, .upper = full };
                    samples = samples_buf[0..1];
                },
                .bc5_unorm_block => {
                    model = 132;
                    bytes = 16;
                    samples_buf[0] = .{ .offset = 0, .bits = 63, .channel = 0, .upper = full };
                    samples_buf[1] = .{ .offset = 64, .bits = 63, .channel = 1, .upper = full };
                    samples = samples_buf[0..2];
                },
                .bc6h_ufloat_block => {
                    model = 133;
                    bytes = 16;
                    samples_buf[0] = .{ .offset = 0, .bits = 127, .channel = 0 | 0x80, .upper = full };
                    samples = samples_buf[0..1];
                },
                .bc7_unorm_block, .bc7_srgb_block => {
                    model = 134;
                    bytes = 16;
                    samples_buf[0] = .{ .offset = 0, .bits = 127, .channel = 0, .upper = full };
                    samples = samples_buf[0..1];
                },
                else => return Error.UnsupportedColorspace,
            }
        },
    }
    const block_size: u32 = 24 + 16 * @as(u32, @intCast(samples.len));
    const w = struct {
        fn u32le(o: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try o.appendSlice(a, &b);
        }
    }.u32le;
    try w(out, gpa, 4 + block_size); // dfdTotalSize
    try w(out, gpa, 0); // vendor 0 (Khronos), type 0 (basic)
    try w(out, gpa, (block_size << 16) | 2); // versionNumber 2 (KDF 1.3)
    const transfer: u32 = if (srgb) 2 else 1;
    try w(out, gpa, @as(u32, model) | (1 << 8) | (transfer << 16)); // primaries BT.709, straight alpha
    try w(out, gpa, std.mem.readInt(u32, &block, .little));
    try w(out, gpa, bytes); // bytesPlane0
    try w(out, gpa, 0); // bytesPlane4..7
    for (samples) |s| {
        try w(out, gpa, @as(u32, s.offset) | (@as(u32, s.bits) << 16) | (@as(u32, s.channel) << 24));
        try w(out, gpa, 0); // sample position
        try w(out, gpa, 0); // lower
        try w(out, gpa, s.upper);
    }
}
