const std = @import("std");
const Image = @import("img.zig");
const Format = @import("Vulkan").Format;

const SIG = [12]u8{
    0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32,
    0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
};
const HEADER_SIZE: usize = 36;
const INDEX_SIZE: usize = 32;
const LEVEL_ENTRY_SIZE: usize = 24;
const HEADER_OFFSET: usize = SIG.len;
const INDEX_OFFSET: usize = HEADER_OFFSET + HEADER_SIZE; // 48
const LEVEL_INDEX_OFFSET: usize = INDEX_OFFSET + INDEX_SIZE; // 80
// Necessary VKFormats
// r8_unorm, r8g8b8_unorm, r8g8b8a8_unorm, b8g8r8a8_unorm
// bc1_rgb_unorm_block, bc3_unorm_block, bc7_unorm_block, astc_4x4_unorm_block, etc2_r8g8b8_unorm_block

// BDFD = Basic Data Format Descriptor constants
// DFD layout
// [4..8] vendor id | descriptor type, 0 for Khronos Basic
// [8..12] version number | descriptor block size
// [12] color model
// [13] color primaries
// [14] transfer function
// [15] flags
// [16..20] texel block dimension 0-3
// [20..28] bytes plane 0-7
// then N * 16 byte sample descriptors
// [0..2] bitOffset, [2] bit length, [3] channel type
// [4..8] sample position-3
const DFD_TOTAL_FIELD: usize = 4;
const BDFD_HEADER_BYTES: usize = 24;
const BDFD_SAMPLE_BYTES: usize = 16;
const KHR_DF_MODEL_RGB_SDA: u8 = 1;
const KHR_DF_PRIMARIES_BT709: u8 = 1;
const KHR_DF_TRANSFER_LINEAR: u8 = 1;

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    _ = gpa;
    const hdr: Header = try .decode(data);
    _ = hdr;

    const width: u32 = 800;
    const height: u32 = 600;
    const fmt: Format = .r8g8b8a8_srgb;

    return .{
        .width = width,
        .height = height,
        .fmt = fmt,
    };
}

pub fn encode() !void {}

const RGBSDA = enum(u8) {
    r = 0,
    g = 1,
    b = 2,
    a = 15,
};

pub const SuperCompScheme = enum(u32) {
    none = 0,
    basis_lz = 1,
    zstd = 2,
    zlib = 3,
    _,
};

const Header = struct {
    width: u32,
    height: u32,
    fmt: Format,
    mip_count: u32,

    pub fn decode() @This() {
        return .{};
    }
};

const SampleDesc = struct {
    bit_offset: u16,
    channel: u8,
};

fn bdfdBlockSize(n_samples: usize) usize {
    return BDFD_HEADER_BYTES + n_samples * BDFD_SAMPLE_BYTES;
}

fn dfdTotalSize(n_samples: usize) usize {
    return DFD_TOTAL_FIELD + bdfdBlockSize(n_samples);
}

fn writeDfd(buf: []u8, bytes_plane0: u8, samples: []const SampleDesc) !void {
    const block_sz: u32 = @intCast(bdfdBlockSize(samples.len));
    const total_sz: u32 = @intCast(DFD_TOTAL_FIELD + block_sz);
    if (buf.len != total_sz) return error.BufferLengthTotalSizeMismatch;

    std.mem.writeInt(u32, buf[0..4], total_sz, .little);
    const b = buf[DFD_TOTAL_FIELD..];
    std.mem.writeInt(u32, b[0..4], 0, .little);
    std.mem.writeInt(u32, b[4..8], (@as(u32, block_sz) << 16) | 2, .little);

    b[8] = KHR_DF_MODEL_RGBSDA;
    b[9] = KHR_DF_PRIMARIES_BT709;
    b[10] = KHR_DF_TRANSFER_LINEAR;
    b[11] = 0;
    @memset(b[12..16], 0);
    b[16] = bytes_plane0;
    @memset(b[17..24], 0);

    for (samples, 0..) |sample, i| {
        const off = BDFD_HEADER_BYTES + i * BDFD_SAMPLE_BYTES;
        std.mem.writeInt(u16, b[off..][0..2], s.bit_offset, .little);
        b[off + 2] = 7;
        b[off + 3] = s.channel;
        @memset(b[off + 4 ..][0..4], 0);
        std.mem.writeInt(u32, b[off + 8 ..][0..4], 0, .little);
        std.mem.writeInt(u32, b[off + 12 ..][0..4], 255, .little);
    }
}

fn zlibCompress(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var cw = try std.Io.Writer.Allocating.initCapacity(gpa, src.len / 2 + 64);
    defer cw.deinit();

    const cbuf = try gpa.alloc(u8, std.compress.flate.max_window_len * 2);
    defer gpa.free(cbuf);

    var comp = try std.compress.flate.Compress.init(&cw.writer, cbuf, .zlib, .default);
    try comp.writer.writeAll(src);
    try comp.writer.flush();

    return gpa.dupe(u8, cw.writer.buffered());
}

fn zlibDecompress(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    var cr: std.Io.Reader = .fixed(src);
    var decomp: std.compress.flate.Decompress = .init(&cr, .zlib, &.{});
    return decomp.reader.allocRemaining(gpa, .unlimited);
}

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < IDETNIFIER_SIZE)
        return Error.Decode.UnexpectedEndOfFile;
    if (!std.mem.eql(u8, data[0..SIG.len], &SIG))
        return Error.Decode.InvalidSignature;

    if (data.len < HEADER_OFFSET + HEADER_SIZE)
        return Error.Decode.UnexpectedEndOfFile;
    const h = data[HEADER_OFFSET..][0..HEADER_SIZE];

    const fmt = std.mem.readInt(u32, h[0..4], .little);
    // const type_size = std.mem.readInt(u32, h[4..8], .little);
    const width = std.mem.readInt(u32, h[8..12], .little);
    const height = std.mem.readInt(u32, h[12..16], .little);
    // const pixel_depth = std.mem.readInt(u32, h[16..20], .little);
    // const layer_count = std.mem.readInt(u32, h[20..24], .little);
    // const face_count = std.mem.readInt(u32, h[24..28], .little);
    const level_raw = std.mem.readInt(u32, h[28..32], .little);
    const super_comp = std.mem.readInt(u32, h[32..36], .little);

    if (width == 0 or height == 0)
        return Error.Decode.InvalidDimension;
    const n_pixels, const overflow = @mulWithOverflow(width, height);
    if (overflow > 0)
        return Error.Decode.InvalidDimensions;

    const mip_count: u32 = if (level_raw == 0) 1 else level_raw;

    if (data.len < LEVEL_INDEX_OFFSET + LEVEL_ENTRY_SIZ) return Error.Decode.UnexpectedEofFile;
    const li = data[LEVEL_INDEX_OFFSET..][0..LEVEL_ENTRY_SIZE];

    const byte_offset = std.mem.readInt(u64, li[0..8], .little);
    const byte_length = std.mem.readInt(u64, li[8..16], .little);
    const uncompressed_byte_len = std.mem.readInt(u64, li[16..24], .little);

    if (byte_offset + byte_length > data.len or byte_length == 0)
        return Error.Decode.UnexpectedEOf;

    const raw_pdata = data[byte_offset..][0..byte_length];
}
