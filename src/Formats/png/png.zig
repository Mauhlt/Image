const std = @import("std");
const Error = @import("../error.zig");

const ChunkHeader = @import("chunk_header.zig");
const ChunkTag = @import("chunk_header.zig").ChunkTag;
const Header = @import("header.zig");
const FilterMethod = @import("header.zig").FilterMethod;
const Image = @import("../../root.zig");
const Pixels = @import("../../Colors/Pixels.zig");

const SIG = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
const CRC_SIZE = 4;

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    var i: usize = 0;
    if (!std.mem.startsWith(u8, data[0..SIG.len], &SIG)) //
        return Error.Decode.UnexpectedSignature;
    i += SIG.len;

    const hdr_chunk: ChunkHeader = try .decode(data[i..]);
    i += ChunkHeader.CHUNK_SIZE;

    if (hdr_chunk.tag != .IHDR) return Error.Decode.MissingIHDR;
    const hdr: Header = try .decode(hdr_chunk.tag.IHDR);
    i += hdr_chunk.len;
    try validateHeader(hdr);

    const bits_per_pixel: u32 = switch (hdr.color_type) {
        .gray => 1,
        .rgb => 3,
        .rgba => 4,
        else => unreachable,
    };
    const bytes_per_row = hdr.width * bits_per_pixel;

    var computed_crc: u32 = chunkCrc(hdr_chunk.tag, hdr_chunk.tag.IHDR);
    var stored_crc: u32 = try readCrc(data[i..]);
    if (computed_crc != stored_crc) return Error.Decode.InvalidCrc;
    i += CRC_SIZE;

    var chunk: ChunkHeader = undefined;
    var seen_idat: bool = false;
    while (i < data.len) {
        chunk = try .decode(data[i..]);
        i += ChunkHeader.CHUNK_SIZE;

        if (chunk.tag == .IEND) break;

        if (i + chunk.len > data.len) return Error.Decode.OutOfBounds;
        const chunk_data = data[i..][0..chunk.len];
        switch (chunk.tag) {
            .unsupported => {
                std.debug.print("{f}\n", .{chunk});
            },
            .IDAT => {
                if (seen_idat) return Error.Decode.UnhandledMultiIDAT;
                seen_idat = true;
                try processIdat(data[i..]);
            },
            .IEND => unreachable,
            else => {},
        }
        i += chunk.len;

        switch (chunk.tag) {
            .unsupported => {},
            .IEND => unreachable,
            else => {
                computed_crc = chunkCrc(chunk.tag, chunk_data);
                stored_crc = try readCrc(data[i..]);
                if (computed_crc != stored_crc) return Error.Decode.InvalidCrc;
            },
        }
        i += CRC_SIZE;
    }
    if (seen_idat == false) return Error.Decode.MissingIDAT;
    if (chunk.tag != .IEND) return Error.Decode.MissingIEND;

    return .{
        .width = 0,
        .height = 0,
        .pixels = undefined,
        // .pixels = .{ .rgbs =  },
        // new_pixels.toOwnedSlice(gpa),
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

fn readCrc(data: []const u8) !u32 {
    if (data.len < CRC_SIZE) return Error.Decode.OutOfBounds;
    return std.mem.readInt(u32, data[0..][0..4], .big);
}

fn chunkCrc(chunk_tag: ChunkTag, data: []const u8) u32 {
    var h = std.hash.Crc32.init();
    h.update(@tagName(chunk_tag));
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

fn processIdat(data: []const u8) []u8 {
    var in: std.Io.Reader = .fixed(data[i..][0..chunk.len]);
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(&in, .zlib, &decompress_buf);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    for (0..hdr.height) |_| {
        const scanline_filter = std.enums.fromInt(
            FilterMethod,
            try decompressor.reader.takeByte(),
        ) orelse //
            return error.InvalidFilterMethod;
        sw: switch (scanline_filter) {
            .none => {
                _ = try decompressor.reader.take(bytes_per_row);
            },
            // .sub => {},
            // .up => {},
            else => {
                std.log.warn("Unimplemented filter: {t}", .{scanline_filter});
                continue :sw .none;
            },
        }
    }
}
