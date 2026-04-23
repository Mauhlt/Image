const std = @import("std");
const Image = @import("img.zig");

const FILE_HEADER_SIZE = 14;
const DIB_HEADER_SIZE = 40;
const HEADER_SIZE = FILE_HEADER_SIZE + DIB_HEADER_SIZE;
const SIGNATURE = "BM";

pub fn decode(gpa: std.mem.Allocator, data: []const u8) !Image {
    if (data.len < HEADER_SIZE) return error.UnexpectedEOF;
    if (std.mem.eql(u8, data[0..SIGNATURE.len], SIGNATURE))
        return error.InvalidSignature;

    const pixel_offset = std.mem.readInt(u32, data[10..][0..4], .little);
    std.debug.print("Pixel Offset: {}\n", .{pixel_offset});

    const dib_size = std.mem.readInt(u32, data[14..][0..4], .little);
    if (dib_size < DIB_HEADER_SIZE) return error.UnsupportedDibHeader;
    std.debug.print("Dib Size: {}\n", .{dib_size});

    const width_signed = std.mem.readInt(i32, data[18..][0..4], .little);
    const height_signed = std.mem.readInt(i32, data[22..][0..4], .little);
    std.debug.print("Raw Width: {}\nRaw Height: {}\n", .{dib_size});
    if (width_signed <= 0) return error.InvalidDimensions;
    if (height_signed == 0) return error.InvalidDimensions;
    const width: u32 = @intCast(width_signed);
    const top_down = height_signed < 0;
    const height: u32 = if (top_down) @intCast(-height_signed) else //
        @intCast(height_signed);
    std.debug.print("Width: {}\nHeight: {}\nTop Down: {}\n", .{ width, height, top_down });

    const n_pixels, const overflow = @mulWithOverflow(width, height);
    if (overflow == 1) return error.InvalidDimensions;
    std.debug.print("# of Pixels: {}\nOverflow: {}\n", .{ n_pixels, overflow });

    const bpp_value = std.mem.readInt(u16, data[28..][0..2], .little);
    const bpp = std.enums.fromInt(BitsPerPixel, bpp_value) orelse //
        return error.UnsupportedBPP;
    std.debug.print("BPP: {t}\nBPP: {}\n", .{ bpp_value, bpp });

    const row_stride = (width * bpp_value + 3) & ~@as(u32, 3); // pad to 4
    const pixel_data_size = row_stride * height;
    if (pixel_offset + pixel_data_size > data.len) return error.InvalidDimensions;
    std.debug.print("Row Stride: {}\nPixel Data Size: {}\n", .{ row_stride, pixel_data_size });

    const compression_value = std.mem.readInt(u32, data[30..][0..4], .little);
    const compression = std.enums.fromInt(Compression, compression_value) orelse //
        return error.UnsupportedCompression;
    if (compression != .none) return error.UnsupportedCompression;

    const compressed_image_size = std.mem.readInt(u32, data[34..][0..4], .little);
    _ = compressed_image_size;
    // const x_px_per_mm = std.mem.readInt(u32, data[38..][0..4], .little);
    // const y_px_per_mm = std.mem.readInt(u32, data[42..][0..4], .little);
    // const colors_used = std.mem.readInt(u32, data[46..][0..4], .little);
    // const important_colors = std.mem.readInt(u32, data[50..][0..4], .little);

    const n_bits_per_pixel = switch (bpp) {
        .rgb_24 => 3,
        .rgba => 4,
        else => unreachable,
    };

    const src = data[54..];

    const pixels = try gpa.alloc(u8, n_pixels * 4);
    errdefer gpa.free(pixels);

    for (0..height) |row| {
        const src_row = if (top_down) row else height - row - 1;
        const dst_row = row;

        const src_base = src_row * row_stride;
        const dst_base = dst_row * width * 4;

        for (0..width) |col| {
            const s = src_base + col * n_bits_per_pixel;
            const d = dst_base + col * 4;

            pixels[d + 0] = src[s + 2];
            pixels[d + 1] = src[s + 1];
            pixels[d + 2] = src[s];
            pixels[d + 3] = if (bpp == .rgba) src[s + 3] else 0xFF;
        }
    }

    return .{
        .width = width,
        .height = height,
        .depth = 1,
        .format = undefined,
        .pixels = pixels,
    };
}

// pub fn encode() !void {}

const BitsPerPixel = enum(u16) {
    monochrome = 1,
    pallet_4_bit = 4,
    pallet_8_bit = 8,
    rgb_16 = 16,
    rgb_24 = 24, // 4 bytes per rgb
    rgba = 32, // 4 bytes per rgba
};

const Compression = enum(u32) {
    bi_rgb = 0,
    bi_rle8 = 1,
    bi_rle4 = 2,
};

fn compressRLE8(gpa: std.mem.Allocator, pixels: []const u8, width: u32, height: u32) !void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const row_start = row * width;
        const row_pixels = pixels[row_start .. row_start + width];

        var col: u32 = 0;
        while (col < width) {
            const start = col;
            const val = row_pixels[col];

            // count run len - max = 255
            var run_len: u32 = 1;
            while (run_len < 255 and col + run_len < width and row_pixels[col + run_len] == val) {
                run_len += 1;
            }

            if (run_len >= 3) {
                try out.append(gpa, @intCast(run_len));
                try out.append(gpa, val);
                col += run_len;
            } else {
                var abs_len: u32 = 0;
                var scan = start;
                while (abs_len < 255 and scan < width) {
                    if (scan + 3 <= width) {
                        if (row_pixels[scan] == row_pixels[scan + 1] and
                            row_pixels[scan] == row_pixels[scan + 2])
                        {
                            if (abs_len >= 3) break;
                        }
                    }
                    abs_len += 1;
                    scan += 1;
                }

                if (abs_len < 3) {
                    try out.append(gpa, @intCast(run_len));
                    try out.append(gpa, val);
                    col += run_len;
                } else {
                    try out.append(gpa, 0);
                    try out.append(gpa, @intCast(abs_len));
                    try out.appendSlice(gpa, row_pixels[start .. start + abs_len]);
                    if (abs_len % 2 != 0) try out.append(gpa, 0);
                    col += abs_len;
                }
            }
        }
        try out.append(gpa, 0);
        try out.append(gpa, 0);
    }
    try out.append(gpa, 0);
    try out.append(gpa, 1);
}

fn decompressRLE8(
    gpa: std.mem.Allocator,
    data: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    // assumes width + height checked
    const n_pixels = width *% height;
    const out = try gpa.alloc(u8, n_pixels);
    errdefer gpa.free(out);
    @memset(out, 0);

    var x: u32 = 0;
    var y: u32 = 0;
    var i: usize = 0;

    while (i < data.len) {
        const b0 = data[i];
        i += 1;
        if (i >= data.len) return error.InvalidData;
        const b1 = data[i];
        i += 1;

        if (b0 != 0) {
            var k: u32 = 0;
            while (k < b0) : (k += 1) {
                if (x >= width or y >= height) return error.InvalidData;
            }
        }
    }
}

fn compressRLE4() void {}

fn decompressRLE4() void {}
