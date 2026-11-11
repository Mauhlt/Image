//! GPU texture: mip levels, array layers, cube faces, raw or block-compressed (BCn).
//!
//! `data` is laid out exactly like a Vulkan staging buffer wants it:
//!     for each level: for each layer: for each face: tightly packed rows / blocks
//! so upload is: memcpy(staging, tex.data) + one VkBufferImageCopy per `regions()` entry.
//! Block-compressed data is never decoded on the CPU for rendering - the GPU does it.
const std = @import("std");
const vk = @import("Vulkan");
const Image = @import("root.zig");
const Info = @import("info.zig");
const misc = @import("misc.zig");
const bc = @import("Formats/bc/bc.zig");
pub const DDS = @import("Formats/dds/dds.zig");
pub const KTX2 = @import("Formats/ktx2/ktx2.zig");

const Texture = @This();

fmt: vk.Format,
width: u32,
height: u32,
levels: u32 = 1,
layers: u32 = 1,
/// 1, or 6 for a cube map (+X, -X, +Y, -Y, +Z, -Z)
faces: u32 = 1,
data: []u8,

pub const Layout = struct {
    /// 1 for plain pixels, 4 for BCn
    block_dim: u32,
    /// bytes per pixel or per block
    block_bytes: u32,
};

/// Memory layout of a format, or null if this library cannot handle it.
pub fn layoutOf(fmt: vk.Format) ?Layout {
    if (bc.Format.fromVk(fmt)) |f| return .{ .block_dim = 4, .block_bytes = @intCast(f[0].blockBytes()) };
    return switch (fmt) {
        .r8_unorm, .r8_srgb => .{ .block_dim = 1, .block_bytes = 1 },
        .r8g8_unorm, .r8g8_srgb => .{ .block_dim = 1, .block_bytes = 2 },
        .r8g8b8a8_unorm, .r8g8b8a8_srgb, .b8g8r8a8_unorm, .b8g8r8a8_srgb => .{ .block_dim = 1, .block_bytes = 4 },
        else => null,
    };
}

pub fn isSrgb(fmt: vk.Format) bool {
    return std.mem.endsWith(u8, @tagName(fmt), "srgb") or std.mem.endsWith(u8, @tagName(fmt), "srgb_block");
}

pub fn levelWidth(self: *const Texture, level: u32) u32 {
    return @max(1, self.width >> @intCast(level));
}

pub fn levelHeight(self: *const Texture, level: u32) u32 {
    return @max(1, self.height >> @intCast(level));
}

/// Bytes of one face of one layer at `level`.
pub fn imageLen(fmt: vk.Format, width: u32, height: u32) usize {
    const l = layoutOf(fmt).?;
    const bx = (width + l.block_dim - 1) / l.block_dim;
    const by = (height + l.block_dim - 1) / l.block_dim;
    return @as(usize, bx) * by * l.block_bytes;
}

pub fn levelLen(self: *const Texture, level: u32) usize {
    return imageLen(self.fmt, self.levelWidth(level), self.levelHeight(level)) * self.layers * self.faces;
}

pub fn totalLen(self: *const Texture) usize {
    var n: usize = 0;
    for (0..self.levels) |l| n += self.levelLen(@intCast(l));
    return n;
}

pub fn offsetOf(self: *const Texture, level: u32, layer: u32, face: u32) usize {
    var off: usize = 0;
    for (0..level) |l| off += self.levelLen(@intCast(l));
    const one = imageLen(self.fmt, self.levelWidth(level), self.levelHeight(level));
    return off + (@as(usize, layer) * self.faces + face) * one;
}

pub fn slice(self: *const Texture, level: u32, layer: u32, face: u32) []u8 {
    const n = imageLen(self.fmt, self.levelWidth(level), self.levelHeight(level));
    return self.data[self.offsetOf(level, layer, face)..][0..n];
}

/// One copy region per level: maps 1:1 to VkBufferImageCopy
/// (bufferOffset, imageSubresource.{mipLevel, baseArrayLayer = 0, layerCount}, imageExtent).
pub const Region = struct {
    level: u32,
    layer_count: u32, // layers * faces
    buffer_offset: usize,
    width: u32,
    height: u32,
};

pub fn regions(self: *const Texture, out: []Region) []Region {
    var off: usize = 0;
    const n = @min(out.len, self.levels);
    for (out[0..n], 0..) |*r, l| {
        const level: u32 = @intCast(l);
        r.* = .{
            .level = level,
            .layer_count = self.layers * self.faces,
            .buffer_offset = off,
            .width = self.levelWidth(level),
            .height = self.levelHeight(level),
        };
        off += self.levelLen(level);
    }
    return out[0..n];
}

pub fn deinit(self: Texture, gpa: std.mem.Allocator) void {
    gpa.free(self.data);
}

pub fn fullMipCount(width: u32, height: u32) u32 {
    return std.math.log2_int(u32, @max(width, height, 1)) + 1;
}

// ───────────────────────────── Creating ─────────────────────────────

pub const TargetFormat = enum {
    rgba8,
    bc1,
    bc3,
    bc4,
    bc5,
    bc7,
};

pub const FromImageOptions = struct {
    format: TargetFormat = .bc7,
    /// sRGB color data (albedo, UI). Use false for normal maps, masks, roughness, ...
    srgb: bool = true,
    /// generate the full mip chain (filtered in linear light when srgb)
    mipmaps: bool = true,
};

pub fn vkFormatFor(target: TargetFormat, srgb: bool) vk.Format {
    return switch (target) {
        .rgba8 => if (srgb) .r8g8b8a8_srgb else .r8g8b8a8_unorm,
        inline else => |t| @field(bc.Format, @tagName(t)).vkFormat(srgb).?,
    };
}

/// Image -> texture (mip chain + block compression). This is the offline / load-time
/// "bake" step; ship the result as .ktx2 or .dds so the game never does it at runtime.
pub fn fromImage(img: *const Image, gpa: std.mem.Allocator, opts: FromImageOptions) !Texture {
    const converted = if (img.pixels == .rgba) null else try img.pixels.convertV(.rgba, gpa);
    defer if (converted) |c| c.deinit(gpa);
    const base = (converted orelse img.pixels).asBytes();

    var tex: Texture = .{
        .fmt = vkFormatFor(opts.format, opts.srgb),
        .width = img.width,
        .height = img.height,
        .levels = if (opts.mipmaps) fullMipCount(img.width, img.height) else 1,
        .data = &.{},
    };
    tex.data = try gpa.alloc(u8, tex.totalLen());
    errdefer gpa.free(tex.data);

    var level_rgba: []u8 = try gpa.dupe(u8, base);
    defer gpa.free(level_rgba);
    for (0..tex.levels) |l| {
        const level: u32 = @intCast(l);
        const w = tex.levelWidth(level);
        const h = tex.levelHeight(level);
        if (level > 0) {
            const next = try downsample(gpa, level_rgba, tex.levelWidth(level - 1), tex.levelHeight(level - 1), opts.srgb);
            gpa.free(level_rgba);
            level_rgba = next;
        }
        const dst = tex.slice(level, 0, 0);
        switch (opts.format) {
            .rgba8 => @memcpy(dst, level_rgba),
            inline else => |t| bc.encodeImage(@field(bc.Format, @tagName(t)), level_rgba, w, h, dst),
        }
    }
    return tex;
}

const srgb_to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const c = @as(f32, @floatFromInt(i)) / 255.0;
        v.* = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    }
    break :blk t;
};

fn linearToSrgb(v: f32) u8 {
    const c = if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(c, 0, 1) * 255));
}

/// 2x2 box filter (odd sizes clamp). RGB averaged in linear light when `srgb`.
fn downsample(gpa: std.mem.Allocator, src: []const u8, w: u32, h: u32, srgb: bool) ![]u8 {
    const nw = @max(1, w / 2);
    const nh = @max(1, h / 2);
    const dst = try gpa.alloc(u8, @as(usize, nw) * nh * 4);
    for (0..nh) |y| for (0..nw) |x| {
        const xs = [2]usize{ @min(2 * x, w - 1), @min(2 * x + 1, w - 1) };
        const ys = [2]usize{ @min(2 * y, h - 1), @min(2 * y + 1, h - 1) };
        for (0..4) |c| {
            var sum: f32 = 0;
            for (ys) |sy| for (xs) |sx| {
                const v = src[(sy * w + sx) * 4 + c];
                sum += if (srgb and c < 3) srgb_to_linear[v] else @as(f32, @floatFromInt(v));
            };
            const avg = sum / 4;
            dst[(y * nw + x) * 4 + c] = if (srgb and c < 3) linearToSrgb(avg) else @intFromFloat(@round(avg));
        }
    };
    return dst;
}

/// CPU decode of one level/layer/face to an RGBA image (previews, tools, tests).
pub fn toImage(self: *const Texture, gpa: std.mem.Allocator, level: u32, layer: u32, face: u32) !Image {
    const w = self.levelWidth(level);
    const h = self.levelHeight(level);
    const src = self.slice(level, layer, face);
    const srgb = isSrgb(self.fmt);
    if (bc.Format.fromVk(self.fmt)) |f| {
        const rgba = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(rgba);
        try bc.decodeImage(f[0], src, w, h, rgba);
        return .{ .width = w, .height = h, .fmt = Info.fmtFor(.rgba, srgb), .pixels = .fromBytes(.rgba, rgba) };
    }
    const tag: Image.PixelTag = switch (self.fmt) {
        .r8_unorm, .r8_srgb => .g,
        .r8g8_unorm, .r8g8_srgb => .ga,
        .b8g8r8a8_unorm, .b8g8r8a8_srgb => .bgra,
        else => .rgba,
    };
    return .{ .width = w, .height = h, .fmt = self.fmt, .pixels = .fromBytes(tag, try gpa.dupe(u8, src)) };
}

// ───────────────────────────── Files ─────────────────────────────

pub const FileTag = enum { dds, ktx2 };

pub fn fileTag(path: []const u8) !FileTag {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".dds")) return .dds;
    if (std.ascii.eqlIgnoreCase(ext, ".ktx2")) return .ktx2;
    return error.InvalidFileExtension;
}

pub fn decode(tag: FileTag, gpa: std.mem.Allocator, data: []const u8) !Texture {
    return switch (tag) {
        .dds => DDS.decode(gpa, data),
        .ktx2 => KTX2.decode(gpa, data),
    };
}

pub fn read(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Texture {
    const tag = try fileTag(path);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    return decode(tag, gpa, try misc.readFileInto(io, gpa, file, &buf));
}

pub fn write(self: *const Texture, io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    const tag = try fileTag(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    switch (tag) {
        .dds => try DDS.encode(self, &fw.interface),
        .ktx2 => try KTX2.encode(self, &fw.interface, gpa),
    }
    try fw.interface.flush();
}

// ───────────────────────────── Tests ─────────────────────────────

test {
    _ = bc;
    _ = DDS;
    _ = KTX2;
}

test "Texture - layout and regions" {
    const t: Texture = .{ .fmt = .bc1_rgba_unorm_block, .width = 10, .height = 6, .levels = 4, .layers = 2, .data = &.{} };
    // 10x6 -> 3x2 blocks * 8 B = 48, 5x3 -> 2x1 = 16, 2x1 -> 8, 1x1 -> 8 ; x2 layers
    try std.testing.expectEqual(@as(usize, (48 + 16 + 8 + 8) * 2), t.totalLen());
    var r: [8]Region = undefined;
    const rs = t.regions(&r);
    try std.testing.expectEqual(@as(usize, 4), rs.len);
    try std.testing.expectEqual(@as(usize, 96 + 32), rs[2].buffer_offset);
    try std.testing.expectEqual(@as(usize, 48), t.offsetOf(0, 1, 0));
    try std.testing.expectEqual(@as(u32, 4), fullMipCount(10, 6));
}

test "Texture - bake, write, read back (dds + ktx2, every format)" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const src = try Image.read(.{ .io = io, .gpa = gpa, .filepath = "src/Data/Read/Gradient.png" });
    defer src.deinit(gpa);
    inline for (comptime std.enums.values(TargetFormat)) |target| {
        const tex = try fromImage(&src, gpa, .{ .format = target, .srgb = target != .bc4 and target != .bc5 });
        defer tex.deinit(gpa);
        try std.testing.expectEqual(fullMipCount(67, 45), tex.levels);
        for ([_][]const u8{ "src/Data/Write/Gradient_" ++ @tagName(target) ++ ".dds", "src/Data/Write/Gradient_" ++ @tagName(target) ++ ".ktx2" }) |path| {
            try tex.write(io, gpa, path);
            const back = try read(io, gpa, path);
            defer back.deinit(gpa);
            try std.testing.expectEqual(tex.fmt, back.fmt);
            try std.testing.expectEqual(tex.levels, back.levels);
            try std.testing.expectEqualSlices(u8, tex.data, back.data);
        }
        // level 0 decodes close to the source
        const img = try tex.toImage(gpa, 0, 0, 0);
        defer img.deinit(gpa);
        if (target == .bc4 or target == .bc5) continue; // channels intentionally dropped
        // BC1 has no real alpha (the source has an alpha ramp), so compare RGB only.
        // Reference: Pillow's BC1 encoder scores 8.09 (RGB) and BC3 6.35 (RGBA) on this image.
        const tag: Image.PixelTag = if (target == .bc1) .rgb else .rgba;
        const tol: f64 = switch (target) {
            .rgba8 => 0,
            .bc1 => 8.5,
            .bc3 => 6.5,
            else => 4, // bc7
        };
        try Image.expectSimilar(gpa, &src, &img, tag, tol);
    }
}

test "Texture - read Pillow DDS files" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cases = [_][2][]const u8{
        .{ "src/Data/Read/GradientDXT1.dds", "src/Data/Read/GradientDXT1.ref.png" },
        .{ "src/Data/Read/GradientDXT3.dds", "src/Data/Read/GradientDXT3.ref.png" }, // BC2 -> transcoded to RGBA8
        .{ "src/Data/Read/GradientDXT5.dds", "src/Data/Read/GradientDXT5.ref.png" },
        .{ "src/Data/Read/GradientBC5.dds", "src/Data/Read/GradientBC5.ref.png" },
        .{ "src/Data/Read/GradientRGBA.dds", "src/Data/Read/Gradient.png" },
    };
    for (cases) |c| {
        const tex = try read(io, gpa, c[0]);
        defer tex.deinit(gpa);
        const img = try tex.toImage(gpa, 0, 0, 0);
        defer img.deinit(gpa);
        const ref = try Image.read(.{ .io = io, .gpa = gpa, .filepath = c[1] });
        defer ref.deinit(gpa);
        Image.expectSimilar(gpa, &ref, &img, .rgba, 0.5) catch |err| {
            std.debug.print("mismatch: {s}\n", .{c[0]});
            return err;
        };
    }
}
