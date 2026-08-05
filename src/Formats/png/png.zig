const std = @import("std");
const Format = @import("Vulkan").Format;
const Error = @import("../error.zig");

const Chunk = @import("chunk.zig");
const Header = @import("header.zig");
const FilterMethod = @import("header.zig").FilterMethod;
const Image = @import("../../root.zig");
const Pixels = @import("../../Colors/Pixels.zig").Pixels;

const SIG = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    var i: usize = 0;

    // sig
    if (!std.mem.startsWith(u8, data[0..SIG.len], &SIG)) //
        return Error.Decode.UnexpectedSignature;
    i += SIG.len;

    // extract hdr
    const hdr_chunk: Chunk = try .decode(data[i..]);
    const hdr: Header = try .decode(hdr_chunk);
    // std.debug.print("{f}", .{hdr});
    try validateHeader(hdr);
    try hdr_chunk.validateCrc();
    i += hdr_chunk.sizeOf();

    // extract chunks
    var has_srgb: bool = false;
    var has_gamma: bool = false;
    var has_idat: bool = false;
    var has_iend: bool = false;
    var pixels: Pixels = undefined;
    while (i < data.len) {
        const chunk: Chunk = try .decode(data[i..]);
        if (i + chunk.len > data.len) return Error.Decode.OutOfBounds;
        // std.debug.print("{f}", .{chunk});
        try chunk.validateCrc();
        switch (chunk.tag) {
            .unsupported => {}, // skip these
            .sRGB => {
                if (has_srgb) return Error.Decode.UnhandledMultiSrgb;
                if (has_idat) return Error.Decode.InvalidChunkOrder;
                has_srgb = true;
                if (chunk.len != 1) return Error.Decode.InvalidChunkLen;
                if (chunk.data[0] != 0) return Error.Decode.UnsupportedSrgb;
            },
            .gAMA => {
                if (has_gamma) return Error.Decode.UnhandledMultiGamma;
                if (has_idat) return Error.Decode.InvalidChunkOrder;
                has_gamma = true;
                if (chunk.len != 4) return Error.Decode.InvalidChunkLen;
                if (!std.mem.eql(u8, chunk.data, &.{ 0, 0, 177, 143 })) //
                    return Error.Decode.UnsupportedGamma;
            },
            .IDAT => {
                if (has_idat) return Error.Decode.UnhandledMultiIdat;
                has_idat = true;
                pixels = try processIdat(gpa, &hdr, chunk.data);
            },
            .IHDR => return Error.Decode.InvalidHeader,
            .IEND => {
                has_iend = true;
                if (chunk.len > 0) return Error.Decode.InvalidChunkLen;
                break;
            },
            else => {},
        }
        i += chunk.sizeOf();
    }
    // validate
    if (!has_idat) return Error.Decode.MissingIdat;
    if (!has_iend) return Error.Decode.MissingIend;

    const fmt: Format = blk: {
        var fmt: Format = undefined;
        if (has_srgb) {
            fmt = switch (pixels) {
                .grays => .r8_srgb,
                .gray_alphas => .r8g8_srgb,
                .rgbs => .r8g8b8_srgb,
                .rgbas => .r8g8b8a8_srgb,
                else => unreachable,
            };
        } else {
            fmt = switch (pixels) {
                .grays => .r8_uint,
                .gray_alphas => .r8g8_uint,
                .rgbs => .r8g8b8_uint,
                .rgbas => .r8g8b8a8_uint,
                else => unreachable,
            };
        }
        break :blk fmt;
    };

    return .{
        .width = hdr.width,
        .height = hdr.height,
        .pixels = pixels,
        .fmt = fmt,
    };
}

pub fn encode(
    img: *const Image,
    w: *std.Io.Writer,
    gpa: std.mem.Allocator,
) !void {
    // FIXME: only works with rgba data currently
    // need to format to use all data (gray, gray_alpha, bgr, bgra, rgb, rgba)
    const src = switch (img.pixels) {
        .rgbas => |rgbas| rgbas,
        else => return Error.Encode.UnsupportedChannel,
    };
    // extract header
    const hdr: Header = .fromImage(img);

    // create  data
    const bpp = try hdr.color_type.bytes_per_pixel(); // bytes per pixel
    const bpr = hdr.width * bpp + 1; // bytes per row
    const dst_size = hdr.height * bpr;
    const dst = try gpa.alloc(u8, dst_size);
    defer gpa.free(dst);
    // alloc mem to get best filter
    const prev_row = try gpa.alloc(u8, bpr - 1);
    defer gpa.free(prev_row);
    @memset(prev_row, 0);
    const cand_buf = try gpa.alloc(u8, bpr - 1);
    defer gpa.free(cand_buf);
    const best_buf = try gpa.alloc(u8, bpr - 1);
    defer gpa.free(best_buf);

    var src_idx: usize = 0;
    var dst_idx: usize = 0;
    while (src_idx < src.len and dst_idx < dst_size) : ({
        src_idx += hdr.width;
        dst_idx += bpr;
    }) {
        const src_bytes: []const u8 = @ptrCast(src[src_idx..][0..hdr.width]);
        // identify best filter = min sum
        var best_filter_method: FilterMethod = .none;
        var min_sum: u64 = std.math.maxInt(u64);
        for (std.enums.values(FilterMethod)) |filter_method| {
            filterRow(cand_buf, filter_method, src_bytes, prev_row, bpp);
            const sum = sumAbs(cand_buf);
            if (sum < min_sum) {
                min_sum = sum;
                best_filter_method = filter_method;
                @memcpy(best_buf, cand_buf);
            }
        }

        const dst_bytes: []u8 = dst[dst_idx..][0..bpr];
        dst_bytes[0] = @intFromEnum(best_filter_method);
        @memcpy(dst_bytes[1..], best_buf);
    }
    // compress w/ zlib
    var comp_aw: std.Io.Writer.Allocating = try .initCapacity(gpa, dst_size / 2 + 128);
    errdefer comp_aw.deinit();
    var hist_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var comp: std.compress.flate.Compress = try .init(&comp_aw.writer, &hist_buf, .zlib, .default);
    try comp.writer.writeAll(dst);
    try comp.finish(); // must be called
    const idat_data = try comp_aw.toOwnedSlice();
    defer gpa.free(idat_data);
    // create chunks
    var hdr_bytes: [13]u8 = undefined;
    try hdr.encode(&hdr_bytes);
    var chunks = [_]Chunk{
        .{ .tag = .IHDR, .len = 13, .data = &hdr_bytes },
        .{ .tag = .sRGB, .len = 1, .data = &.{0} },
        .{ .tag = .gAMA, .len = 4, .data = &.{ 0, 0, 177, 143 } },
        .{ .tag = .IDAT, .len = @truncate(idat_data.len), .data = idat_data },
        .{ .tag = .IEND, .len = 0, .data = &.{} },
    };
    for (0..chunks.len) |i| chunks[i].crc = chunks[i].updateCrc();
    // write
    try w.writeAll(SIG[0..SIG.len]);
    for (0..chunks.len) |i| try chunks[i].encode(w);
    try w.flush();
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

fn filterRow(
    out: []u8,
    filter_method: FilterMethod,
    row: []const u8,
    prev: []const u8,
    bpp: usize,
) void {
    switch (filter_method) {
        .none => @memcpy(out, row),
        .sub => {
            for (0..bpp) |i| out[i] = row[i];
            for (bpp..row.len) |i| out[i] = row[i] -% row[i - bpp];
        },
        .up => for (0..row.len) |i| {
            out[i] = row[i] -% prev[i];
        },
        .avg => {
            for (0..bpp) |i| out[i] = row[i] -% @as(u8, @truncate(prev[i] / 2));
            for (bpp..row.len) |i| {
                const a: u16 = row[i - bpp];
                const b: u16 = prev[i];
                out[i] = row[i] -% @as(u8, @truncate((a + b) / 2));
            }
        },
        .paeth => {
            for (0..bpp) |i| out[i] = row[i] -% paethPredictor(0, prev[i], 0);
            for (bpp..row.len) |i| {
                out[i] = row[i] -% paethPredictor(row[i - bpp], prev[i], prev[i - bpp]);
            }
        },
    }
}

fn sumAbs(row: []const u8) u64 {
    var sum: u64 = 0;
    for (row) |r| sum += @abs(@as(i16, @as(i8, @bitCast(r))));
    return sum;
}

fn defilterRow(
    filter_method: FilterMethod,
    row: []u8,
    prev: []const u8,
    bpp: usize,
) !void {
    if (row.len != prev.len) return Error.Decode.InvalidDataLen;
    switch (filter_method) {
        .none => {},
        .sub => for (bpp..row.len) |i| {
            row[i] = row[i] +% row[i - bpp];
        },
        .up => for (0..row.len) |i| {
            row[i] = row[i] +% prev[i];
        },
        .avg => {
            if (bpp > row.len) return Error.Decode.InvalidDataLen;
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
            if (bpp > row.len) return Error.Decode.InvalidDataLen;
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
    const bytes_per_row = hdr.width * (try hdr.color_type.bytes_per_pixel());
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

    var prev_row = try gpa.alloc(u8, bytes_per_row);
    defer gpa.free(prev_row);
    @memset(prev_row, 0);

    var curr_row = try gpa.alloc(u8, bytes_per_row);
    defer gpa.free(curr_row);

    const pixels: Pixels = switch (hdr.color_type) {
        .indices => return Error.Decode.UnsupportedColorspace,
        inline else => |tag| sw: {
            const CHILD_TYPE = @typeInfo(@FieldType(Pixels, @tagName(tag))).pointer.child;
            const slice = try gpa.alloc(CHILD_TYPE, n_pixels);
            break :sw @unionInit(Pixels, @tagName(tag), slice);
        },
    };

    for (0..hdr.height) |row| {
        // copy data to buffer
        const i = row * (1 + bytes_per_row);
        const filter_method = std.enums.fromInt(FilterMethod, raw[i]) orelse //
            return Error.Decode.UnsupportedFilterMethod;
        @memcpy(curr_row, raw[i + 1 ..][0..bytes_per_row]);
        // modify buffer
        try defilterRow(
            filter_method,
            curr_row,
            prev_row,
            try hdr.color_type.bytes_per_pixel(),
        );
        // copy buffer to pixel array
        switch (hdr.color_type) {
            .indices => unreachable,
            inline else => |tag| {
                const CHILD_TYPE = @typeInfo(@FieldType(Pixels, @tagName(tag))).pointer.child;
                @memcpy(
                    @field(pixels, @tagName(tag))[row * hdr.width ..][0..hdr.width],
                    @as([]CHILD_TYPE, @ptrCast(curr_row)),
                );
            }
        }
        std.mem.swap([]u8, &prev_row, &curr_row); // need to swap curr + prev rows!
    }
    return pixels;
}
