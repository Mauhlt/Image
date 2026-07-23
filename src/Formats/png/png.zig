const std = @import("std");
const isSigSame = @import("../misc.zig").isSigSame;
const Error = @import("../error.zig");

const ChunkHeader = @import("chunk_header.zig");
const ChunkTypeEnums = @import("chunk_header.zig").Type;
const Header = @import("header.zig");
const ColorType = @import("header.zig").ColorType;
const Image = @import("../../root.zig");
const Pixels = @import("../../Colors/Pixels.zig");

const SIG = "\x89PNG\r\n\x1a\n";

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (!std.mem.startsWith(u8, data[0..SIG.len], SIG)) //
        return Error.Decode.UnexpectedSignature;

    var i: usize = SIG.len;
    var header: ?Header = null;

    var idat_buf: std.ArrayList(u8) = .empty;
    defer idat_buf.deinit(gpa);

    while (i < data.len) {
        if (i + 12 > data.len) return Error.Decode.UnexpectedEndOfData;

        const length = std.mem.readInt(u32, data[i..][0..4], .big);
        const chunk_type = data[i + 4 ..][0..4];
        i += 8;

        if (i + length + 4 > data.len) return Error.Decode.UnexpectedEndOfData;

        const chunk_data = data[i .. i + length];
        const stored_crc = std.mem.readInt(u32, data[i + length ..][0..4], .big);
        i += length + 4;

        const computed_crc = chunkCrc(chunk_type, chunk_data);
        if (computed_crc != stored_crc) return Error.Decode.InvalidCrc;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {}
    }
}

pub fn encode(
    self: *const @This(),
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    img: *const Image,
) !void {
    const hdr: Header = try .fromImage(img);
    const n_pixels = hdr.width * hdr.height;

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
