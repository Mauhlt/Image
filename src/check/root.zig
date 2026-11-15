//! Image.check: cheap structural validation of encoded images, BEFORE decoding.
//!
//! Given the bytes of a file and the `Limits` the caller is willing to pay
//! for, `check` finds the format from its signature (or `checkAs` takes it
//! from the caller), validates the container/header structure without
//! decoding any pixels, and returns the format, the dimensions and an
//! estimate of what Image's decoder will allocate for it - or a precise
//! `Error` saying what is wrong.
//!
//!     const info = try check.check(bytes, .{ .max_bytes = 8 << 20, .max_pixels = 16 << 20 });
//!     // info.format, info.width, info.height, info.decode_bytes
//!
//! Properties, for every format and every input:
//!   * no allocation, no I/O, never panics (fuzzed by the tests below);
//!   * every header field Image's decoder relies on is range-checked;
//!   * the size limits are applied as soon as the dimensions are known, so
//!     an oversized image is refused before its body is looked at.
//!
//! `check` / `checkAs` validate the whole file where the format allows it
//! cheaply (PNG: every chunk's bounds and CRC, chunk order, IEND; JPEG: every
//! segment up to the first scan; RIFF and ISO-BMFF boxes); `checkHeader` /
//! `checkHeaderAs` read only as far as the dimensions (a size peek for
//! layout, e.g. while a decode is pending or impossible).
//!
//! Passing a check does not promise the decode succeeds (entropy-coded data
//! is not decoded); it promises the decoder is only handed well-formed
//! structure and that its cost is within `limits`. Callers decoding
//! untrusted data should still cap the decoder's allocator.
//!
//! This module depends on std only (no Vulkan) and compiles for any target,
//! wasm32-freestanding included. Image's own module re-exports it as
//! `Image.check`; other programs can import the "ImageCheck" module alone.
const std = @import("std");

/// PNG-compatible CRC-32 (slicing-by-16), shared with Image's PNG codec.
pub const crc = @import("crc.zig");
pub const png = @import("png.zig");
/// JPEG (baseline, extended, progressive, lossless SOF3) and JPEG-LS.
pub const jpeg = @import("jpeg.zig");
pub const bmp = @import("bmp.zig");
pub const webp = @import("webp.zig");
pub const qoi = @import("qoi.zig");
pub const tga = @import("tga.zig");
/// PBM / PGM / PPM (P1..P6) and PAM (P7).
pub const netpbm = @import("netpbm.zig");
/// HEIC (HEIF with HEVC images).
pub const heif = @import("heif.zig");
pub const dds = @import("dds.zig");
pub const ktx2 = @import("ktx2.zig");

/// Every format the checker knows. Names match `Image.ImageTag` where the
/// two overlap (`Image.tagOf` converts).
pub const Format = enum {
    png,
    jpg,
    jls,
    bmp,
    webp,
    qoi,
    tga,
    pbm,
    pgm,
    ppm,
    pam,
    heic,
    /// DirectDraw Surface texture container (`Image.Texture`).
    dds,
    /// Khronos KTX 2 texture container (`Image.Texture`).
    ktx2,
    /// Recognised by signature, but Image has no decoder for them:
    /// checking one returns `error.UnsupportedFormat`.
    gif,
    tif,
};

/// What the caller is willing to accept. A check fails with `FileTooLarge`,
/// `ImageTooLarge`, `DecodeTooLarge` or `TooManyChunks` past these.
/// The defaults are generous but finite; `Limits.none` turns them all off.
pub const Limits = struct {
    /// Largest input, in bytes.
    max_bytes: u64 = 512 << 20,
    /// Largest width and height, in pixels.
    max_width: u32 = 1 << 15,
    max_height: u32 = 1 << 15,
    /// Largest width * height.
    max_pixels: u64 = 1 << 28,
    /// Largest `Info.decode_bytes` (estimated decoder memory).
    max_decode_bytes: u64 = 4 << 30,
    /// Most chunks / segments / boxes walked (a file of a million empty
    /// chunks is structurally valid but only good for burning CPU).
    max_chunks: u32 = 1 << 16,

    pub const none: Limits = .{
        .max_bytes = std.math.maxInt(u64),
        .max_width = std.math.maxInt(u32),
        .max_height = std.math.maxInt(u32),
        .max_pixels = std.math.maxInt(u64),
        .max_decode_bytes = std.math.maxInt(u64),
        .max_chunks = std.math.maxInt(u32),
    };

    /// `ImageTooLarge` unless `w x h` is within the limits; `InvalidDimensions` for 0.
    pub fn admit(l: Limits, w: u32, h: u32) Error!void {
        if (w == 0 or h == 0) return error.InvalidDimensions;
        if (w > l.max_width or h > l.max_height) return error.ImageTooLarge;
        if (@as(u64, w) * h > l.max_pixels) return error.ImageTooLarge;
    }
};

pub const Error = error{
    /// No known signature (`check`), or the bytes are not the format given
    /// to `checkAs`.
    UnknownFormat,
    /// A format recognised by signature that Image cannot decode (GIF, TIFF).
    UnsupportedFormat,
    /// Well-formed, but uses something Image's decoder does not implement
    /// (animation, arithmetic coding, CMYK, 3D textures, an unknown critical
    /// PNG chunk, a JPEG-LS file given as `.jpg`, ...).
    UnsupportedFeature,
    /// The data ends before the structure it declares.
    Truncated,
    /// A header field is malformed or out of its legal range.
    InvalidHeader,
    /// Width or height is 0.
    InvalidDimensions,
    /// Bits per sample / per pixel not allowed (for this colour type).
    InvalidBitDepth,
    /// Colour type / channel layout not allowed.
    InvalidColorType,
    /// Unknown compression method.
    InvalidCompression,
    /// Unknown filter method (PNG IHDR).
    InvalidFilterMethod,
    /// Unknown interlace method (PNG IHDR).
    InvalidInterlaceMethod,
    /// A chunk / segment / box has a bad length or tag.
    InvalidChunk,
    /// A chunk's checksum does not match.
    InvalidCrc,
    /// Chunks in an order the format forbids.
    InvalidChunkOrder,
    /// No image data (no IDAT, no scan, no bitstream, no pixels).
    MissingImageData,
    /// The end marker (PNG IEND) is missing.
    MissingEnd,
    /// More chunks than `Limits.max_chunks`.
    TooManyChunks,
    /// More bytes than `Limits.max_bytes`.
    FileTooLarge,
    /// Width, height or pixel count over the limits.
    ImageTooLarge,
    /// `Info.decode_bytes` over `Limits.max_decode_bytes`.
    DecodeTooLarge,
};

/// What a check learned.
pub const Info = struct {
    format: Format,
    width: u32,
    height: u32,
    /// Channels of the image as stored, alpha included when the header says
    /// so: 1 gray, 2 gray + alpha, 3 colour, 4 colour + alpha (palette
    /// images count as colour).
    channels: u8,
    /// Bits per stored sample (palette index bits for palette images;
    /// 8 for block-compressed textures).
    bits: u8,
    /// Estimated peak bytes Image's decoder allocates for this file: its
    /// output pixels plus the format's intermediate buffers. An upper bound
    /// for PNG; an estimate for the others.
    decode_bytes: u64,
    /// The PNG header, for `.png`.
    png: ?png.Header = null,

    pub fn pixels(i: Info) u64 {
        return @as(u64, i.width) * i.height;
    }
};

/// How far a check reads.
pub const Depth = enum {
    /// Signature and header: dimensions and header fields only.
    header,
    /// The whole structure the format lets us walk without decoding.
    full,
};

/// The format of `data` from its signature, or null. Needs only the first
/// bytes (TGA, which has no signature, is found by its 2.0 footer only;
/// give a footer-less TGA to `checkAs`).
pub fn detect(data: []const u8) ?Format {
    if (png.sniff(data)) return .png;
    if (jpeg.sniff(data)) return jpeg.sniffFormat(data);
    if (webp.sniff(data)) return .webp;
    if (qoi.sniff(data)) return .qoi;
    if (bmp.sniff(data)) return .bmp;
    if (dds.sniff(data)) return .dds;
    if (ktx2.sniff(data)) return .ktx2;
    if (heif.sniff(data)) return .heic;
    if (netpbm.sniff(data)) |f| return f;
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return .gif;
    if (data.len >= 4 and (std.mem.eql(u8, data[0..4], "II*\x00") or std.mem.eql(u8, data[0..4], "MM\x00*"))) return .tif;
    if (tga.sniff(data)) return .tga;
    return null;
}

/// Detects the format and validates the whole file.
pub fn check(data: []const u8, limits: Limits) Error!Info {
    return run(detect(data) orelse return error.UnknownFormat, data, limits, .full);
}

/// Validates the whole file as `format`.
pub fn checkAs(format: Format, data: []const u8, limits: Limits) Error!Info {
    return run(format, data, limits, .full);
}

/// Detects the format and reads only its header (dimensions, limits).
pub fn checkHeader(data: []const u8, limits: Limits) Error!Info {
    return run(detect(data) orelse return error.UnknownFormat, data, limits, .header);
}

/// Reads only the header of `data` as `format`.
pub fn checkHeaderAs(format: Format, data: []const u8, limits: Limits) Error!Info {
    return run(format, data, limits, .header);
}

fn run(format: Format, data: []const u8, limits: Limits, depth: Depth) Error!Info {
    if (data.len > limits.max_bytes) return error.FileTooLarge;
    const info: Info = switch (format) {
        .png => try png.check(data, limits, depth),
        .jpg, .jls => try jpeg.check(data, limits, depth, format),
        .bmp => try bmp.check(data, limits, depth),
        .webp => try webp.check(data, limits, depth),
        .qoi => try qoi.check(data, limits, depth),
        .tga => try tga.check(data, limits, depth),
        .pbm, .pgm, .ppm, .pam => try netpbm.check(data, limits, depth, format),
        .heic => try heif.check(data, limits, depth),
        .dds => try dds.check(data, limits, depth),
        .ktx2 => try ktx2.check(data, limits, depth),
        .gif, .tif => return error.UnsupportedFormat,
    };
    try limits.admit(info.width, info.height);
    if (info.decode_bytes > limits.max_decode_bytes) return error.DecodeTooLarge;
    return info;
}

/// Saturating a * b (decode estimates must not overflow on hostile headers).
pub fn mul(a: u64, b: u64) u64 {
    return std.math.mul(u64, a, b) catch std.math.maxInt(u64);
}

/// Bounds-checked big/little-endian reads for the format checkers.
pub fn int(comptime T: type, data: []const u8, at: usize, endian: std.builtin.Endian) Error!T {
    const n = @sizeOf(T);
    if (at > data.len or data.len - at < n) return error.Truncated;
    return std.mem.readInt(T, data[at..][0..n], endian);
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

test {
    _ = crc;
    _ = png;
    _ = jpeg;
    _ = bmp;
    _ = webp;
    _ = qoi;
    _ = tga;
    _ = netpbm;
    _ = heif;
    _ = dds;
    _ = ktx2;
}

test "detect and limits" {
    const gpa = testing.allocator;
    const p = try png.fixtures.testImage(gpa, 40, 30);
    defer gpa.free(p);
    try testing.expectEqual(Format.png, detect(p).?);
    const info = try check(p, .{});
    try testing.expectEqual(Format.png, info.format);
    try testing.expectEqual(@as(u32, 40), info.width);
    try testing.expectEqual(@as(u32, 30), info.height);
    try testing.expectEqual(@as(u8, 4), info.channels);
    try testing.expectError(error.FileTooLarge, check(p, .{ .max_bytes = p.len - 1 }));
    try testing.expectError(error.ImageTooLarge, check(p, .{ .max_width = 39 }));
    try testing.expectError(error.ImageTooLarge, check(p, .{ .max_height = 29 }));
    try testing.expectError(error.ImageTooLarge, check(p, .{ .max_pixels = 40 * 30 - 1 }));
    try testing.expectError(error.DecodeTooLarge, check(p, .{ .max_decode_bytes = 100 }));
    try testing.expectError(error.TooManyChunks, check(p, .{ .max_chunks = 2 }));
    _ = try check(p, .none);
    _ = try checkHeader(p, .{});

    try testing.expectEqual(@as(?Format, null), detect(""));
    try testing.expectEqual(@as(?Format, null), detect("hello, world"));
    try testing.expectError(error.UnknownFormat, check("hello, world", .{}));
    try testing.expectEqual(Format.gif, detect("GIF89a\x01\x00\x01\x00").?);
    try testing.expectError(error.UnsupportedFormat, check("GIF89a\x01\x00\x01\x00", .{}));
    try testing.expectError(error.UnsupportedFormat, check("II*\x00\x08\x00\x00\x00", .{}));
    // The wrong format for the bytes.
    try testing.expectError(error.UnknownFormat, checkAs(.qoi, p, .{}));
    try testing.expectError(error.UnknownFormat, checkAs(.webp, p, .{}));
}

test "random and mutated bytes never panic, in any format" {
    var prng: std.Random.DefaultPrng = .init(0xC0FFEE);
    const rand = prng.random();
    var buf: [600]u8 = undefined;
    const gpa = testing.allocator;
    const p = try png.fixtures.testImage(gpa, 9, 5);
    defer gpa.free(p);
    // A plausible prefix per format, so mutations reach past the signature.
    const prefixes = [_][]const u8{
        &png.signature,                 "\xFF\xD8\xFF\xC0\x00\x11\x08", "\xFF\xD8\xFF\xF7\x00\x0B\x08",
        "BM",                           "RIFF\x40\x00\x00\x00WEBPVP8L", "RIFF\x40\x00\x00\x00WEBPVP8X",
        "RIFF\x40\x00\x00\x00WEBPVP8 ", "qoif",                         "P1 ",
        "P5\n",                         "P7\nWIDTH ",                   "\x00\x00\x00\x18ftypheic",
        "DDS \x7C\x00\x00\x00",         "\xABKTX 20\xBB\r\n\x1A\n",     "\x00\x00\x02\x00\x00\x00\x00\x00",
    };
    for (0..40000) |_| {
        const n = rand.uintAtMost(usize, buf.len);
        switch (rand.uintLessThan(u8, 3)) {
            0 => {
                @memcpy(buf[0..p.len], p);
                for (0..rand.uintAtMost(usize, 4)) |_| buf[rand.uintLessThan(usize, p.len)] = rand.int(u8);
                if (rand.boolean()) png.fixtures.fixCrcs(buf[0..p.len]);
                _ = check(buf[0..@min(n, p.len)], .{}) catch {};
            },
            1 => {
                rand.bytes(buf[0..n]);
                const pre = prefixes[rand.uintLessThan(usize, prefixes.len)];
                if (n >= pre.len) @memcpy(buf[0..pre.len], pre);
                _ = check(buf[0..n], .{}) catch {};
                _ = checkHeader(buf[0..n], .{}) catch {};
            },
            else => {
                rand.bytes(buf[0..n]);
                for (std.enums.values(Format)) |f| {
                    _ = checkAs(f, buf[0..n], .none) catch {};
                }
            },
        }
    }
}
