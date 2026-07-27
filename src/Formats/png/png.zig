const std = @import("std");
const Error = @import("../error.zig");

const ChunkHeader = @import("chunk_header.zig");
const Header = @import("header.zig");
const Image = @import("../../root.zig");
const Pixels = @import("../../Colors/Pixels.zig");

const SIG = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    _ = gpa;
    var i: usize = 0;
    if (!std.mem.startsWith(u8, data[0..SIG.len], &SIG)) //
        return Error.Decode.UnexpectedSignature;
    i += SIG.len;
    if (data[i..].len < 13) return error.InvalidDataLength;
    const hdr: Header = try .decode(data[i..][0..13]);
    try validateHeader(hdr);
    i += @sizeOf(Header);

    // while (i < data.len) {
    //     const chunk: ChunkHeader = try .decode(data[i..]);
    //     std.debug.print("{f}\n", .{chunk});
    //     // var seen_idat: bool = false;
    //     // switch (chunk.type) {
    //     //     .IDAT => {
    //     //         if (seen_idat) return error.UnhandledMultiIdat;
    //     //         seen_idat = true;
    //     //         const uncompressed_data = try decompress(gpa, hdr, data[i..]);
    //     //         defer gpa.free(uncompressed_data);
    //     //     },
    //     //     else => {},
    //     // }
    //     i += chunk.len;
    //     if (chunk.tag == .IEND) break;
    // }
    return .{
        .width = 0,
        .height = 0,
        .pixels = undefined,
        .fmt = .r8g8b8_srgb,
    };
}

pub fn encode(
    self: *const @This(),
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    img: *const Image,
) !void {
    _ = self;
    _ = w;
    const hdr: Header = try .fromImage(img);
    const n_pixels = hdr.width * hdr.height;
    _ = n_pixels;

    const row_bytes = hdr.width * 4;
    const raw_size = hdr.height * (1 + row_bytes);
    const raw = try gpa.alloc(u8, raw_size);
    defer gpa.free(raw);

    // is it better to keep the data as []const u8
    // then based on the type of fn it is conduct a conversion?
    // switch (img.pixels) {
    //     .grays => |grays| {
    //         for (0..hdr.height) |row| {
    //             const raw_base = row * (1 + row_bytes);
    //             raw[raw_base] = 0;
    //             const src_base = row * row_bytes;
    //             @memcpy(raw[raw_base + 1 .. raw_base + 1 + row_bytes], grays[src_base .. src_base + row_bytes]);
    //         }
    //     },
    //     .rgbs => |rgbs| {},
    //     .bgrs => |bgrs| {},
    //     .rgbas => |rgbas| {},
    //     .bgras => |bgras| {},
    // }
}

fn validateHeader(hdr: Header) !void {
    if (hdr.bit_depth != .bit8) return Error.Decode.UnsupportedBitsPerPixel;
    switch (hdr.color_type) {
        .gray, .rgb, .rgba => {},
        else => return Error.Decode.UnsupportedColorspace,
    }
    if (hdr.filter_method != .none) return Error.Decode.UnsupportedFilterMethod;
    if (hdr.interlace_method != .none) return Error.Decode.UnsupportedInterlaceMethod;
}

fn decompress(
    gpa: std.mem.Allocator,
    hdr: Header,
    compressed: []const u8,
) ![]u8 {
    var in: std.Io.Reader = .fixed(compressed);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&in, .zlib, &window_buf); // .zlib, .raw

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const scanline_size = hdr.width * switch (hdr.color_type) {
        .gray => 1,
        .rgb => 3,
        .rgba => 4,
        else => unreachable,
    } + 1;

    for (0..hdr.height) |_| {
        _ = try decompressor.reader.take(scanline_size);
        // _ = try decompressor.reader.streamRemaining(&out.writer);
    }
    return out.toOwnedSlice();
}

fn chunkCrc(chunk_type: []const u8, data: []const u8) u32 {
    var h = std.hash.Crc32.init();
    h.update(chunk_type);
    h.update(data);
    return h.final();
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ia: i32 = a;
    const ib: i32 = b;
    const ic: i32 = c;
    const p = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn defilterRow(filter: u8, row: []u8, prev: []const u8, bpp: usize) !void {
    switch (filter) {
        0 => {}, // no change
        1 => for (bpp..row.len) |i| {
            row[i] = row[i] +% row[i - bpp];
        },
        2 => for (0..row.len) |i| {
            row[i] = row[i] +% prev[i];
        },
        3 => for (0..row.len) |i| {
            const a: u16 = if (i >= bpp) row[i - bpp] else 0;
            const b: u16 = prev[i];
            row[i] = row[i] +% @as(u8, @truncate((a + b) / 2));
        },
        4 => for (0..row.len) |i| {
            const a: u8 = if (i >= bpp) row[i - bpp] else 0;
            const b: u8 = prev[i];
            const c: u8 = if (i >= bpp) prev[i - bpp] else 0;
            row[i] = row[i] +% paethPredictor(a, b, c);
        },
        else => return error.InvalidFilterType,
    }
}
