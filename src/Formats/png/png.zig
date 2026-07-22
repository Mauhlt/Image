const std = @import("std");
const isSigSame = @import("../misc.zig").isSigSame;
const Error = @import("../error.zig").Decode;

const ChunkHeader = @import("chunk_header.zig");
const ChunkTypeEnums = @import("chunk_header.zig").Type;
const ColorType = @import("header.zig").ColorType;
const Image = @import("../../root.zig");
const Pixels = @import("../../Colors/Pixels.zig");

const SIG = "\x89PNG\r\n\x1a\n";

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !void { // !Image {
    if (std.mem.eql(u8, data[0..SIG.len], SIG)) {}
}

pub fn encode(
    self: *const @This(),
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
    img: *const Image,
) !void {
    _ = gpa;
    _ = img;
    try self.hdr.write(w);
    try self.body.write(w);
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
