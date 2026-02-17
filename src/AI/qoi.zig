const std = @import("std");
const testing = std.testing;

pub const DecodeError = error{
    InvalidSignature,
    InvalidChannels,
    InvalidColorspace,
    InvalidDimensions,
    UnexpectedEndOfData,
};

pub const Channels = enum(u8) {
    rgb = 3,
    rgba = 4,
};

pub const Colorspace = enum(u8) {
    srgb = 0,
    linear = 1,
};

pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0xFF,

    pub fn eql(self: Color, other: Color) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b and self.a == other.a;
    }
};

pub const QoiHeader = struct {
    width: u32,
    height: u32,
    channels: Channels,
    colorspace: Colorspace,
};

pub const QoiImage = struct {
    header: QoiHeader,
    pixels: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *QoiImage) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    /// Returns the pixel color at (x, y).
    pub fn getPixel(self: *const QoiImage, x: u32, y: u32) Color {
        const channels: u32 = @intFromEnum(self.header.channels);
        const idx = (y * self.header.width + x) * channels;
        return .{
            .r = self.pixels[idx],
            .g = self.pixels[idx + 1],
            .b = self.pixels[idx + 2],
            .a = if (channels == 4) self.pixels[idx + 3] else 0xFF,
        };
    }
};

fn hash(c: Color) u6 {
    return @truncate(c.r *% 3 +% c.g *% 5 +% c.b *% 7 +% c.a *% 11);
}

/// Decode a QOI image from raw bytes in memory.
pub fn decode(data: []const u8, allocator: std.mem.Allocator) !QoiImage {
    // 14 bytes = header, 8 bytes = termination sequence
    if (data.len < 14 + 8) return DecodeError.InvalidSignature;

    // Validate magic bytes "qoif"
    if (!std.mem.eql(u8, data[0..4], "qoif"))
        return DecodeError.InvalidSignature;

    // Parse header (big-endian)
    const width = std.mem.readInt(u32, data[4..8], .big);
    const height = std.mem.readInt(u32, data[8..12], .big);
    const channels_byte = data[12];
    const colorspace_byte = data[13];

    if (width == 0 or height == 0) return DecodeError.InvalidDimensions;

    const channels: Channels = std.meta.intToEnum(Channels, channels_byte) catch
        return DecodeError.InvalidChannels;
    const colorspace: Colorspace = std.meta.intToEnum(Colorspace, colorspace_byte) catch
        return DecodeError.InvalidColorspace;

    const num_channels: u32 = @intFromEnum(channels);
    const pixel_count: u32, const overflow: u1 = @mulWithOverflow(width, height);
    if (overflow != 0) return error.InvalidDimensions;
    const pixel_data_len: usize = @intCast(pixel_count * num_channels);

    const pixels = try allocator.alloc(u8, pixel_data_len);
    errdefer allocator.free(pixels);

    // Decode chunks
    var index: [64]Color = [_]Color{.{}} ** 64;
    var prev: Color = .{};
    var pos: usize = 14; // start after header
    var pixel_idx: usize = 0;

    while (pixel_idx < pixel_data_len) {
        if (pos >= data.len - 8) return DecodeError.UnexpectedEndOfData;

        const b1 = data[pos];

        switch (b1) {
            0xFE => {
                // QOI_OP_RGB
                prev.r = data[pos + 1];
                prev.g = data[pos + 2];
                prev.b = data[pos + 3];
                pos += 4;
            },
            0xFF => {
                // QOI_OP_RGBA
                prev.r = data[pos + 1];
                prev.g = data[pos + 2];
                prev.b = data[pos + 3];
                prev.a = data[pos + 4];
                pos += 5;
            },
            else => {
                const tag = b1 >> 6;
                switch (tag) {
                    0b00 => {
                        // QOI_OP_INDEX
                        const idx: u6 = @truncate(b1);
                        prev = index[idx];
                        pos += 1;
                    },
                    0b01 => {
                        // QOI_OP_DIFF
                        const dr: i8 = @as(i8, @intCast((b1 >> 4) & 0x03)) - 2;
                        const dg: i8 = @as(i8, @intCast((b1 >> 2) & 0x03)) - 2;
                        const db: i8 = @as(i8, @intCast(b1 & 0x03)) - 2;
                        prev.r = @bitCast(@as(i8, @bitCast(prev.r)) +% dr);
                        prev.g = @bitCast(@as(i8, @bitCast(prev.g)) +% dg);
                        prev.b = @bitCast(@as(i8, @bitCast(prev.b)) +% db);
                        pos += 1;
                    },
                    0b10 => {
                        // QOI_OP_LUMA
                        const b2 = data[pos + 1];
                        const dg: i8 = @as(i8, @intCast(b1 & 0x3F)) - 32;
                        const dr_dg: i8 = @as(i8, @intCast(b2 >> 4)) - 8;
                        const db_dg: i8 = @as(i8, @intCast(b2 & 0x0F)) - 8;
                        const dr: i8 = dr_dg +% dg;
                        const db: i8 = db_dg +% dg;
                        prev.r = @bitCast(@as(i8, @bitCast(prev.r)) +% dr);
                        prev.g = @bitCast(@as(i8, @bitCast(prev.g)) +% dg);
                        prev.b = @bitCast(@as(i8, @bitCast(prev.b)) +% db);
                        pos += 2;
                    },
                    0b11 => {
                        // QOI_OP_RUN
                        const run: u8 = (b1 & 0x3F) + 1;
                        var i: u8 = 0;
                        while (i < run) : (i += 1) {
                            if (pixel_idx >= pixel_data_len) break;
                            pixels[pixel_idx] = prev.r;
                            pixels[pixel_idx + 1] = prev.g;
                            pixels[pixel_idx + 2] = prev.b;
                            if (num_channels == 4) {
                                pixels[pixel_idx + 3] = prev.a;
                            }
                            pixel_idx += num_channels;
                        }
                        // Update hash index for the run pixel
                        index[hash(prev)] = prev;
                        continue;
                    },
                    else => unreachable,
                }
            }
        }

        // Store pixel and update hash index
        index[hash(prev)] = prev;
        pixels[pixel_idx] = prev.r;
        pixels[pixel_idx + 1] = prev.g;
        pixels[pixel_idx + 2] = prev.b;
        if (num_channels == 4) {
            pixels[pixel_idx + 3] = prev.a;
        }
        pixel_idx += num_channels;
    }

    return QoiImage{
        .header = .{
            .width = width,
            .height = height,
            .channels = channels,
            .colorspace = colorspace,
        },
        .pixels = pixels,
        .allocator = allocator,
    };
}

/// Load a QOI image from a file path.
pub fn loadFromFile(filepath: []const u8, allocator: std.mem.Allocator) !QoiImage {
    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer file.close();

    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    defer allocator.free(data);

    const bytes_read = try file.readAll(data);
    if (bytes_read != stat.size) return DecodeError.UnexpectedEndOfData;

    return decode(data, allocator);
}

// ─── Unit Tests ─────────────────────────────────────────────────────────

test "decode valid QOI file from disk" {
    const allocator = testing.allocator;
    var image = try loadFromFile("src/Images/BasicArt.qoi", allocator);
    defer image.deinit();

    // Header must have been parsed with sensible values
    try testing.expect(image.header.width > 0);
    try testing.expect(image.header.height > 0);
    try testing.expect(image.header.channels == .rgb or image.header.channels == .rgba);
    try testing.expect(image.header.colorspace == .srgb or image.header.colorspace == .linear);

    // Pixel buffer length must match dimensions * channels
    const expected_len = @as(usize, image.header.width) *
        @as(usize, image.header.height) *
        @intFromEnum(image.header.channels);
    try testing.expectEqual(expected_len, image.pixels.len);
}

test "reject invalid signature" {
    const allocator = testing.allocator;
    // 22 bytes: 14 header + 8 end marker, but wrong magic
    var bad = [_]u8{0} ** 22;
    bad[0] = 'b';
    bad[1] = 'a';
    bad[2] = 'd';
    bad[3] = '!';
    const result = decode(&bad, allocator);
    try testing.expectError(DecodeError.InvalidSignature, result);
}

test "reject data that is too short" {
    const allocator = testing.allocator;
    const short = [_]u8{ 'q', 'o', 'i', 'f' };
    const result = decode(&short, allocator);
    try testing.expectError(DecodeError.InvalidSignature, result);
}

test "hash function produces values 0..63" {
    // Verify the hash never exceeds 63 for a sample of colours
    const colours = [_]Color{
        .{ .r = 0, .g = 0, .b = 0, .a = 255 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
        .{ .r = 128, .g = 64, .b = 32, .a = 0 },
        .{ .r = 1, .g = 2, .b = 3, .a = 4 },
    };
    for (colours) |c| {
        const h = hash(c);
        try testing.expect(h < 64);
    }
}
