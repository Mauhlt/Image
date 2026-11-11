//! HEIC: HEVC-coded still images in a HEIF container. Decode only.
//! Handles grids, the clean aperture crop, rotation, mirroring and an alpha
//! plane; samples are converted to 8-bit RGB(A) with the file's matrix and range.
const std = @import("std");
const Error = @import("../error.zig").Error;
const Image = @import("../../root.zig");
const Info = @import("../../info.zig");
const PixelTag = @import("../../Colors/pixels.zig").PixelTag;
const heif = @import("heif.zig");
const hevc = @import("hevc/hevc.zig");

pub fn info(data: []const u8) !Info {
    // the container's item tables are small; parse them in a throwaway arena
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const img = try heif.parse(arena_state.allocator(), data);
    const w, const h = img.outputSize();
    const tag: PixelTag = if (img.alpha != null) .rgba else .rgb;
    return .{ .width = w, .height = h, .tag = tag, .fmt = Info.fmtFor(tag, true) };
}

pub fn decodeInto(scratch: std.mem.Allocator, data: []const u8, inf: Info, out: []u8) !void {
    const channels: usize = switch (inf.tag) {
        .rgb => 3,
        .rgba => 4,
        else => return Error.UnsupportedPixels,
    };
    var arena_state: std.heap.ArenaAllocator = .init(scratch);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const img = try heif.parse(arena, data);
    const out_w, const out_h = img.outputSize();
    if (out_w != inf.width or out_h != inf.height) return Error.InvalidDimensions;
    if (img.tiles.len != @as(usize, img.columns) * img.rows) return Error.InvalidHeader;

    // the whole (uncropped, unrotated) image, then the transforms into `out`
    const w: usize = img.width;
    const h: usize = img.height;
    const canvas = try arena.alloc(u8, w * h * channels);
    if (channels == 4) @memset(canvas, 255);

    const tile_w: usize = img.tiles[0].width;
    const tile_h: usize = img.tiles[0].height;
    for (img.tiles, 0..) |t, i| {
        var tile_arena: std.heap.ArenaAllocator = .init(arena);
        defer tile_arena.deinit();
        const pic = try hevc.decode(tile_arena.allocator(), t.param_sets, t.length_size, t.data);
        const x0 = (i % img.columns) * tile_w;
        const y0 = (i / img.columns) * tile_h;
        try toRgb(tile_arena.allocator(), &pic, colorOf(img, &pic), canvas, w, h, channels, x0, y0);
    }
    if (channels == 4) if (img.alpha) |alpha| try decodeAlpha(arena, img, alpha, canvas, w, h);

    transform(img, canvas, w, channels, out, out_w, out_h);
}

pub fn encode(img: *const Image, w: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    _ = .{ img, w, gpa };
    return Error.UnsupportedFeature;
}

/// YCbCr -> RGB coefficients for one picture (H.273 matrix + range).
const Color = struct {
    identity: bool, // matrix 0: the planes are G, B, R
    y_off: i32,
    c_off: i32,
    // 16.16 fixed point, already scaled for bit depth and range
    y_mul: i32,
    cr_r: i32,
    cb_g: i32,
    cr_g: i32,
    cb_b: i32,
};

/// The `colr` box wins; otherwise the HEVC VUI.
fn colorOf(img: heif.Image, pic: *const hevc.Picture) Color {
    const matrix: u16 = if (img.color.explicit) img.color.matrix else pic.sps.matrix;
    const full = if (img.color.explicit) img.color.full_range else pic.sps.video_full_range;
    const kr: f64, const kb: f64 = switch (matrix) {
        // unspecified (2) follows Windows / HD-video practice: BT.709
        1, 2 => .{ 0.2126, 0.0722 }, // BT.709
        4 => .{ 0.30, 0.11 }, // FCC
        7 => .{ 0.212, 0.087 }, // SMPTE 240M
        9, 10 => .{ 0.2627, 0.0593 }, // BT.2020
        else => .{ 0.299, 0.114 }, // BT.601 (5, 6)
    };
    const kg = 1 - kr - kb;
    const bd = pic.sps.bit_depth_luma;
    const scale = @as(f64, @floatFromInt(@as(u32, 1) << @intCast(bd - 8)));
    // to 0..255: luma (Y - off) * ys, chroma (C - mid) * cs
    const ys: f64 = @as(f64, if (full) 1.0 else 255.0 / 219.0) / scale;
    const cs: f64 = @as(f64, if (full) 1.0 else 255.0 / 224.0) / scale;
    const fx = struct {
        fn f(v: f64) i32 {
            return @intFromFloat(@round(v * 65536));
        }
    }.f;
    return .{
        .identity = matrix == 0,
        .y_off = if (full) 0 else @as(i32, 16) << @intCast(bd - 8),
        .c_off = @as(i32, 1) << @intCast(bd - 1),
        .y_mul = fx(ys),
        .cr_r = fx(2 * (1 - kr) * cs),
        .cb_g = fx(2 * (1 - kb) * kb / kg * cs),
        .cr_g = fx(2 * (1 - kr) * kr / kg * cs),
        .cb_b = fx(2 * (1 - kb) * cs),
    };
}

/// Converts the picture's display window (SPS conformance crop) into the
/// canvas at (x0, y0), clipped to the canvas.
fn toRgb(arena: std.mem.Allocator, pic: *const hevc.Picture, col: Color, canvas: []u8, cw: usize, ch: usize, channels: usize, x0: usize, y0: usize) !void {
    const sps = pic.sps;
    const left: usize = sps.crop_left;
    const top: usize = sps.crop_top;
    const w = @min(@as(usize, sps.width - sps.crop_left - sps.crop_right), cw -| x0);
    const h = @min(@as(usize, sps.height - sps.crop_top - sps.crop_bottom), ch -| y0);
    const mono = sps.chroma_format_idc == 0;
    const cb_up = try arena.alloc(u16, pic.width[0]);
    const cr_up = try arena.alloc(u16, pic.width[0]);
    const half: i32 = 1 << 15;
    for (0..h) |y| {
        const sy = y + top;
        const row = pic.planes[0][sy * pic.width[0] ..][0..pic.width[0]];
        if (!mono) {
            upsampleRow(pic, 1, sy, cb_up);
            upsampleRow(pic, 2, sy, cr_up);
        }
        const dst = canvas[((y0 + y) * cw + x0) * channels ..];
        for (0..w) |x| {
            const sx = x + left;
            const yv: i32 = row[sx];
            var r: i32 = undefined;
            var g: i32 = undefined;
            var b: i32 = undefined;
            if (mono) {
                r = ((yv - col.y_off) * col.y_mul + half) >> 16;
                g = r;
                b = r;
            } else if (col.identity) {
                g = (yv * col.y_mul + half) >> 16;
                b = (@as(i32, cb_up[sx]) * col.y_mul + half) >> 16;
                r = (@as(i32, cr_up[sx]) * col.y_mul + half) >> 16;
            } else {
                const cb = @as(i32, cb_up[sx]) - col.c_off;
                const cr = @as(i32, cr_up[sx]) - col.c_off;
                const yy = (yv - col.y_off) * col.y_mul + half;
                r = (yy + col.cr_r * cr) >> 16;
                g = (yy - col.cb_g * cb - col.cr_g * cr) >> 16;
                b = (yy + col.cb_b * cb) >> 16;
            }
            const d = dst[x * channels ..];
            d[0] = @intCast(std.math.clamp(r, 0, 255));
            d[1] = @intCast(std.math.clamp(g, 0, 255));
            d[2] = @intCast(std.math.clamp(b, 0, 255));
        }
    }
}

/// One luma row's worth of chroma, bilinearly upsampled for 4:2:0 with the
/// default siting (chroma_sample_loc_type 0): co-sited with even luma columns,
/// halfway between luma rows.
fn upsampleRow(pic: *const hevc.Picture, c: usize, sy: usize, out: []u16) void {
    const plane = pic.planes[c];
    const cw = pic.width[c];
    if (pic.chroma_shift == 0) {
        @memcpy(out, plane[sy * cw ..][0..cw]);
        return;
    }
    const k = sy >> 1;
    // the nearer chroma row weighs 3/4, the other 1/4
    const other = if (sy & 1 == 0) k -| 1 else @min(k + 1, pic.height[c] - 1);
    const r0 = plane[k * cw ..][0..cw];
    const r1 = plane[other * cw ..][0..cw];
    for (out, 0..) |*o, x| {
        const a = x >> 1;
        const va = 3 * @as(u32, r0[a]) + r1[a];
        const sum = if (x & 1 == 0) 2 * va else blk: {
            const b = @min(a + 1, cw - 1);
            break :blk va + 3 * @as(u32, r0[b]) + r1[b];
        };
        o.* = @intCast((sum + 4) >> 3);
    }
}

/// The auxiliary alpha image: one item, or a grid with the same layout as the colour image.
fn decodeAlpha(arena: std.mem.Allocator, img: heif.Image, alpha: []heif.Coded, canvas: []u8, cw: usize, ch: usize) !void {
    if (alpha.len != 1 and alpha.len != img.tiles.len) return Error.InvalidHeader;
    const tile_w: usize = alpha[0].width;
    const tile_h: usize = alpha[0].height;
    for (alpha, 0..) |t, i| {
        var tile_arena: std.heap.ArenaAllocator = .init(arena);
        defer tile_arena.deinit();
        const pic = try hevc.decode(tile_arena.allocator(), t.param_sets, t.length_size, t.data);
        const sps = pic.sps;
        const x0 = if (alpha.len == 1) 0 else (i % img.columns) * tile_w;
        const y0 = if (alpha.len == 1) 0 else (i / img.columns) * tile_h;
        const w = @min(@as(usize, sps.width - sps.crop_left - sps.crop_right), cw -| x0);
        const h = @min(@as(usize, sps.height - sps.crop_top - sps.crop_bottom), ch -| y0);
        const shift: u4 = @intCast(sps.bit_depth_luma - 8);
        for (0..h) |y| for (0..w) |x| {
            const v = pic.planes[0][(y + sps.crop_top) * pic.width[0] + x + sps.crop_left];
            canvas[((y0 + y) * cw + x0 + x) * 4 + 3] = @intCast(v >> shift);
        };
    }
}

/// Crop, then counter-clockwise quarter turns, then mirror (HEIF's required order).
fn transform(img: heif.Image, canvas: []const u8, cw: usize, channels: usize, out: []u8, ow: usize, oh: usize) void {
    const crop: heif.Image.Crop = img.crop orelse .{ .x = 0, .y = 0, .width = img.width, .height = img.height };
    const w: usize = crop.width; // size before rotation
    const h: usize = crop.height;
    for (0..oh) |oy| for (0..ow) |ox| {
        // undo the mirror (in rotated space)
        var x = ox;
        var y = oy;
        if (img.mirror) |m| switch (m) {
            .vertical_axis => x = ow - 1 - x,
            .horizontal_axis => y = oh - 1 - y,
        };
        // undo the rotation: source (sx, sy) in the w x h cropped image
        const sx: usize, const sy: usize = switch (img.rotation) {
            0 => .{ x, y },
            1 => .{ w - 1 - y, x },
            2 => .{ w - 1 - x, h - 1 - y },
            3 => .{ y, h - 1 - x },
        };
        const src = ((sy + crop.y) * cw + sx + crop.x) * channels;
        const dst = (oy * ow + ox) * channels;
        @memcpy(out[dst..][0..channels], canvas[src..][0..channels]);
    };
}

test "HEIC samples vs. Windows' decoder (WIC)" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_][]const u8{ "C002", "C014", "C021" }) |name| {
        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "src/Data/Read/heic/{s}.heic", .{name});
        const img = try Image.read(.{ .io = io, .gpa = gpa, .filepath = path });
        defer img.deinit(gpa);
        const ref_path = try std.fmt.bufPrint(&buf, "src/Data/Read/heic/{s}.heic.wic.png", .{name});
        const ref = try Image.read(.{ .io = io, .gpa = gpa, .filepath = ref_path });
        defer ref.deinit(gpa);
        try std.testing.expectEqual(ref.width, img.width);
        try std.testing.expectEqual(ref.height, img.height);
        // WIC's chroma upsampling and rounding differ slightly (measured: mean
        // 0.17 / 0.24, max 17 at sharp chroma edges)
        const a = img.pixels.asBytes();
        const b = ref.pixels.asBytes();
        var sum: u64 = 0;
        var max: u8 = 0;
        const n = @as(usize, img.width) * img.height;
        const sa = a.len / n;
        const sb = b.len / n;
        for (0..n) |i| for (0..3) |c| {
            const d = @as(u8, @intCast(@abs(@as(i16, a[i * sa + c]) - b[i * sb + c])));
            sum += d;
            max = @max(max, d);
        };
        const mean = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n * 3));
        try std.testing.expect(mean < 0.3);
        try std.testing.expect(max <= 20);
    }
}
