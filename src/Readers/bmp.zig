const std = @import("std");

/// Must load both bmp and dib
/// BMP = bitmap
/// DIB = device independent bitmap
pub fn readBMP(r: *std.Io.Reader) !void {
    const exp_sig = [_][]const u8{ 0x42, 0x4D };
    if (!std.mem.eql(u8, sig, exp_sig))
        return DecodeError.InvalidSignature;

    // header
    const hdr = try Header.read(r);
}

const BMPHeader = struct {
    width: u32,
    height: u32,

    pub fn read(r: *std.Io.Reader) !@This() {
        // bmp header
        const bmp_hdr_str = try r.take(14);

        const sig = std.meta.stringToEnum(Signatures, bmp_hdr_str[0..2]) orelse
            return DecodeError.InvalidSignature;
        if (sig != .BM) return DecodeError.UnsupportedSignature;

        const size: u32 = @bitCast(bmp_hdr_str[2..][0..4].*);
        const reserved: u16 = @bitCast(bmp_hdr_str[6..][0..2].*); // if manual = 0, otherwise depends on app that creates image
        const reserved2: u16 = @bitCast(bmp_hdr_str[8..][0..2].*); // if manual = 0, otherwise depends on app that creates image
        const start: u32 = @bitCast(bmp_hdr_str[10..][0..4].*); // starting address of bitmap image data - using this you can skip the rest
        _ = reserved;
        _ = reserved2;
        _ = start;

        // unsupported: os22qbitmapheader, os22qbitmapheader, bitmapv2infoheader, bitmapv3infoheader, bitmapv4header, bitmapv5header

        // bitmap core header:
        // const dib_hdr_str = try r.take(12);
        // const dib_size: u32 = @bitCast(dib_hdr_str[0..4]);
        // const width: u16 = @bitCast(dib_hdr_str[4..][0..2]); // signed ints for windows 2.x bitmapcoreheader
        // const height: u16 = @bitCast(dib_hdr_str[6..][0..2]);
        // const num_color_panes: u16 = @bitCast(dib_hdr_str[8..][0..2]);
        // const num_bits_per_pixel: u16 = @bitCast(dib_hdr_str[10..][0..2]);

        // bitmapinfoheader:
        // const dib_hdr_str = try r.take(40);
        // const size_1: u32 = @bitCast(dib_hdr_str[14..][0..4].*); // of header
        // const width: u32 = @bitCast(dib_hdr_str[18..][0..4].*);
        // const height: u32 = @bitCast(dib_hdr_str[22][0..4].*);
        // const num_color_panes: u16 = @bitCast(dib_hdr_str[26..][0..2].*);
        // const num_bits_per_pixel: u16 = @bitCast(dib_hdr_str[28..][0..2].*); // must be 1, 4, 8, 16, 24, 32
        // const compression_method: CompressionMethod = @enumFromInt(@as(u32, @bitCast(dib_hdr_str[30..][0..4].*)));
        // const image_size: u32 = @bitCast(dib_hdr_str[34..][0..4].*);
        // const horizontal_resolution: u32 = @bitCast(dib_hdr_str[38..][0..4].*);
        // const vertical_resolution: u32 = @bitCast(dib_hdr_str[42..][0..4].*);
        // const num_colors_per_palette: u32 = @bitCast(dib_hdr_str[46..][0..4].*); // 0 or 2^n
        // const important_colors: u32 = @bitCast(dib_hdr_str[50..][0..4].*);

        // os22xbitmapheader = bitmapinfoheader2
        const dib_hdr_str = try r.take()

        return @This(){
            .width = width,
            .height = height,
        };
    }
};

const DecodeError = error{
    InvalidSignature,
    UnsupportedSignature,
};

const Signatures = enum(u8) {
    BM, // Windows BMP, same for DIB
    BA, // OS/2 struct bitmap array
    CI, // OS/2 struct color icon
    CP, // OS/2 const color ptr
    IC, // OS/2 struct icon
    PT, // OS/2 ptr
};

const CompressionMethod = enum(u32) {
    rgb = 0, // most common, none
    rle8 = 1, // 8 bit/pixel bitmaps
    rle4 = 2, // 4 bit/pixel bitmaps
    bitfields = 3, // v2: rgb bit field masks, v3+: rgba
    jpeg = 4, // v4+: jpeg
    png = 5, // v4+: png
    alphabitfields = 6, // windows ce 5.0 + Net 4.0
    cmyk = 11, // windows metafile cmyk
    cmyk_rle8 = 12, // windows metafile cmyk
    cmyk_rle4 = 13, // windows metafile cmyk
};

const HalftoningAlgorithmEnum = enum(u8) {
    none = 0, // most common
    error_diffusion = 1, // param 1, % of error damping, 100% = none, 0% = errors are not diffuse
    panda = 2, // Processing Algorithm For Noncoded Document  Acquisition, params 1 + 2, represents x + y dims in pixels
    super_circle = 3, // params 1 + 2, represents x + y dims
};

/// Color Table:
/// In BMP image file after BMP hdr + DIB hdr + 3/4 bitmasks if bitinfoheadr w/ bitfields (12 bytes) or alphabitfields (16 bytes)
/// number of entries = 2^n or header in bitmapcoreheader
/// 4 bytes per entry: blue, greend, red, 0x00
/// each pixel described by number of bits: 1, 4, 8
const ColorTable = struct {

};

fn getRowSize(bits_per_pixel: u32, width: u32) u32 {
    return (bits_per_pixel * width + 31) / 32 * 4;
}

fn getPixelArraySize(row_size: u32, height: i32) u32 {
    return row_size * @as(u32, @abs(height));
}
