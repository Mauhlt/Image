const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../error.zig");

const ChunkHeader = @import("chunk_header.zig");
const ChunkTag = @import("chunk_header.zig").ChunkTag;
const Header = @import("header.zig");
const FilterMethod = @import("header.zig").FilterMethod;
const Image = @import("../../root.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

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

    var computed_crc: u32 = chunkCrc(hdr_chunk.tag, hdr_chunk.tag.IHDR);
    var stored_crc: u32 = try readCrc(data[i..]);
    if (computed_crc != stored_crc) return Error.Decode.InvalidCrc;
    i += CRC_SIZE;

    var chunk: ChunkHeader = undefined;
    var seen_idat: bool = false;
    var pixels: Pixels = undefined;
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
                pixels = try processIdat(gpa, &hdr, data[i..][0..chunk.len]);
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
    const fmt: Format = switch (pixels) {
        .grays => .r8_srgb,
        .gray_alphas => .r8g8_srgb,
        .rgbs => .r8g8b8_srgb,
        .rgbas => .r8g8b8a8_srgb,
        else => unreachable,
    };
    return .{
        .width = 0,
        .height = 0,
        .pixels = pixels,
        .fmt = fmt,
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
        .grays, .rgbs, .rgbas => {},
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

fn defilterRow(filter_method: FilterMethod, row: []u8, prev: []const u8, bpp: usize) !void {
    if (row.len != prev.len) return Error.Decode.InvalidDataLength;
    switch (filter_method) {
        .none => {},
        .sub => for (bpp..row.len) |i| {
            row[i] = row[i] +% row[i - bpp];
        },
        .up => for (0..row.len) |i| {
            row[i] = row[i] +% prev[i];
        },
        .avg => {
            if (bpp > row.len) return Error.Decode.InvalidDataLength;
            for (0..bpp) |i| {
                row[i] = row[i] +% (prev[i] / 2);
            }
            for (bpp..row.len) |i| {
                const a: u16 = row[i - bpp];
                const b: u16 = prev[i];
                row[i] = row[i] +% @as(u8, @truncate((a + b) / 2));
            }
        },
        .paeth => {
            if (bpp > row.len) return Error.Decode.InvalidDataLength;
            for (0..bpp) |i| {
                row[i] = row[i] +% paethPredictor(0, prev[i], 0);
            }
            for (bpp..row.len) |i| {
                const a: u8 = row[i - bpp];
                const b: u8 = prev[i];
                const c: u8 = prev[i - bpp];
                row[i] = row[i] +% paethPredictor(a, b, c);
            }
        },
    }
}

fn processIdat(
    gpa: std.mem.Allocator,
    hdr: *const Header,
    data: []const u8,
) !Pixels {
    const bytes_per_row = hdr.width * (try hdr.color_type.bits_per_pixel());
    const total_bytes = hdr.height * (1 + bytes_per_row);

    // decompress
    var idat_reader: std.Io.Reader = .fixed(data);
    var decompress: std.compress.flate.Decompress = .init(&idat_reader, .zlib, &.{});
    var base: std.Io.Writer.Allocating = try .initCapacity(gpa, total_bytes + 16);
    errdefer base.deinit();
    _ = decompress.reader.streamRemaining(&base.writer) catch |err| switch (err) {
        error.WriteFailed => return Error.Decode.OutOfMemory,
        error.ReadFailed => return Error.Decode.DecompressionFailed,
    };

    // extract pixels
    const raw = try base.toOwnedSlice();
    defer gpa.free(raw);

    const expected_size = hdr.height * (1 + bytes_per_row);
    if (raw.len < expected_size) return Error.Decode.UnexpectedEndOfData;

    const n_pixels, const overflow = @mulWithOverflow(hdr.width, hdr.height);
    if (overflow == 1) return Error.Decode.Overflow;

    const prev_row = try gpa.alloc(u8, bytes_per_row);
    defer gpa.free(prev_row);
    @memset(prev_row, 0);

    const curr_row = try gpa.alloc(u8, bytes_per_row);
    defer gpa.free(curr_row);

    const pixels: Pixels = switch (hdr.color_type) {
        .indices => return Error.Decode.UnsupportedColorspace,
        inline else => |tag| sw: {
            const CHILD_TYPE = @typeInfo(@FieldType(Pixels, @tagName(tag))).pointer.child;
            const slice = try gpa.alloc(CHILD_TYPE, n_pixels);
            break :sw @unionInit(Pixels, @tagName(tag), slice);
        },
    };

    // for (0..hdr.height) |row| {
    //     const i = row * (1 + bytes_per_row);
    //     const filter_method = std.enums.fromInt(FilterMethod, raw[i]) orelse //
    //         return error.UnsupportedFilterMethod;
    //     @memcpy(curr_row, raw[i + 1 ..][0..bytes_per_row]);
    //
    //     try defilterRow(filter_method, curr_row, prev_row, hdr.color_type.bits_per_pixel());
    //
    //     const dst_base = row * hdr.width * hdr.color_type.bits_per_pixel();
    //     switch (hdr.color_type) {
    //         .gray => for (0..hdr.width) |col| {
    //             // const v = row_buf[col];
    //             // const d = dst_base + col * 4;
    //             // pixels.grays[i] = v;
    //         },
    //         .gray_alpha => unreachable,
    //         .rgb => {},
    //         .rgba => @memcpy(rgbas[dst_base..][0 .. hdr.width * 4], curr_row),
    //         .indexed => unreachable,
    //     }
    // }

    return pixels;
}
