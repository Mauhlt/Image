const std = @import("std");

pub const DEFAULT_QUALITY: u8 = 85;

/// Row-major (natural) index of the k-th coefficient in zig-zag order.
pub const ZIGZAG = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// Annex K.1 - natural order
pub const BASE_LUMA_QUANT = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

pub const BASE_CHROMA_QUANT = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

/// IJG quality scaling. quality: 1 (worst) .. 100 (best)
pub fn scaleQuantTable(base: *const [64]u8, desired_quality: u8) [64]u16 {
    const quality: i32 = @max(1, @min(desired_quality, 100));
    const scale: i32 = if (quality < 50) @divTrunc(5000, quality) else 200 - quality * 2;
    var out: [64]u16 = undefined;
    for (&out, base) |*o, b| {
        const value = @divTrunc(@as(i32, b) * scale + 50, 100);
        o.* = @intCast(@max(@min(value, 255), 1));
    }
    return out;
}

/// Second byte of a 0xFF?? marker.
pub const Marker = enum(u8) {
    TEM = 0x01, // standalone, arithmetic-coding temporary
    SOF0 = 0xC0, // baseline DCT, huffman
    SOF1 = 0xC1, // extended sequential DCT, huffman
    SOF2 = 0xC2, // progressive DCT, huffman
    SOF3 = 0xC3, // lossless, huffman
    DHT = 0xC4,
    SOF5 = 0xC5,
    SOF6 = 0xC6,
    SOF7 = 0xC7,
    JPG = 0xC8,
    SOF9 = 0xC9, // arithmetic coding variants
    SOF10 = 0xCA,
    SOF11 = 0xCB,
    DAC = 0xCC,
    SOF13 = 0xCD,
    SOF14 = 0xCE,
    SOF15 = 0xCF,
    RST0 = 0xD0,
    RST1 = 0xD1,
    RST2 = 0xD2,
    RST3 = 0xD3,
    RST4 = 0xD4,
    RST5 = 0xD5,
    RST6 = 0xD6,
    RST7 = 0xD7,
    SOI = 0xD8,
    EOI = 0xD9,
    SOS = 0xDA,
    DQT = 0xDB,
    DNL = 0xDC,
    DRI = 0xDD,
    APP0 = 0xE0, // JFIF
    APP1 = 0xE1, // EXIF/XMP
    APP14 = 0xEE, // Adobe
    SOF55 = 0xF7, // JPEG-LS (T.87)
    LSE = 0xF8, // JPEG-LS preset parameters
    SOF57 = 0xF9, // JPEG-LS extensions (T.870)
    COM = 0xFE,
    _,

    /// Markers without a length / segment body (B.1.1.3, T.87 C.1.1).
    pub fn standalone(m: Marker) bool {
        return switch (m) {
            .TEM, .SOI, .EOI, .RST0, .RST1, .RST2, .RST3, .RST4, .RST5, .RST6, .RST7 => true,
            else => false,
        };
    }
};

/// A marker and its segment body (the bytes after the length field; empty for
/// standalone markers).
pub const Segment = struct { marker: Marker, body: []const u8 };

/// Walks the marker segments of a JPEG / JPEG-LS stream. `pos` is public so a
/// decoder can step over a scan's entropy-coded data (see `entropyEnd`).
pub const Segments = struct {
    data: []const u8,
    /// offset of the next marker (or fill byte); 2 = after SOI
    pos: usize = 2,

    pub const NextError = error{ InvalidMarker, UnexpectedEndOfData };

    /// The next segment, or null at the end of the data. Markers may be
    /// preceded by any number of 0xFF fill bytes.
    pub fn next(self: *Segments) NextError!?Segment {
        const data = self.data;
        var pos = self.pos;
        if (pos >= data.len) return null;
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos < data.len and data[pos] == 0xFF) pos += 1;
        if (pos >= data.len) return error.UnexpectedEndOfData;
        const marker: Marker = @fromBackingInt(@intCast(data[pos]));
        pos += 1;
        if (marker.standalone()) {
            self.pos = pos;
            return .{ .marker = marker, .body = &.{} };
        }
        if (pos + 2 > data.len) return error.UnexpectedEndOfData;
        const len = std.mem.readInt(u16, data[pos..][0..2], .big);
        if (len < 2) return error.InvalidMarker;
        if (pos + len > data.len) return error.UnexpectedEndOfData;
        self.pos = pos + len;
        return .{ .marker = marker, .body = data[pos + 2 .. pos + len] };
    }
};

/// Offset of the marker that ends the entropy-coded data starting at `start`
/// (skipping stuffed 0xFF00 bytes and RSTn markers), or `data.len`.
pub fn entropyEnd(data: []const u8, start: usize) usize {
    var i = start;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] != 0xFF) continue;
        const m = data[i + 1];
        if (m == 0x00 or (m >= 0xD0 and m <= 0xD7)) {
            i += 1;
            continue;
        }
        if (m == 0xFF) continue; // fill byte before a marker
        return i;
    }
    return data.len;
}

pub fn ceilDiv(a: usize, b: usize) usize {
    return (a + b - 1) / b;
}
