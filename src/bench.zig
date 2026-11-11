//! `zig build bench` (ReleaseFast). Decode time per format + Batch vs. one-by-one loading.
const std = @import("std");
const Image = @import("Image");

const N_ITERS = 20;
const BATCH_N = 64;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;

    std.debug.print("{s:<34} {s:>10} {s:>12}\n", .{ "decode (1536x864)", "ms", "MPix/s" });
    const files = [_][]const u8{
        "src/Data/Read/BasicArt.bmp",  "src/Data/Read/BasicArt.ppm", "src/Data/Read/BasicArt.tga",
        "src/Data/Read/BasicArt.qoi",  "src/Data/Read/BasicArt.png", "src/Data/Read/BasicArt.webp",
        "src/Data/Read/BasicArt.jpg",  "src/Data/Read/IjgProgressive.jpg",
    };
    for (files) |path| {
        const tag = try Image.tagFromExt(path);
        const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        defer gpa.free(data);
        const inf = try Image.info(tag, data);
        const out = try gpa.alloc(u8, try inf.byteLen());
        defer gpa.free(out);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const start = nowNs(io);
        for (0..N_ITERS) |_| {
            try Image.decodeInto(tag, arena.allocator(), data, inf, out);
            _ = arena.reset(.retain_capacity);
        }
        const ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6 / N_ITERS;
        const mpix = @as(f64, @floatFromInt(try inf.nPixels())) / 1e6;
        std.debug.print("{s:<34} {d:>10.2} {d:>12.1}\n", .{ path, ms, mpix / (ms / 1000) });
    }

    // Game path: bake once (offline), then load the GPU-ready texture at runtime
    {
        const src = try Image.read(.{ .io = io, .gpa = gpa, .filepath = "src/Data/Read/BasicArt.png" });
        defer src.deinit(gpa);
        var start = nowNs(io);
        const tex = try Image.Texture.fromImage(&src, gpa, .{ .format = .bc7 });
        defer tex.deinit(gpa);
        const bake_ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6;
        try tex.write(io, gpa, "src/Data/Write/BasicArt_bc7.ktx2");
        start = nowNs(io);
        for (0..N_ITERS) |_| {
            const t = try Image.Texture.read(io, gpa, "src/Data/Write/BasicArt_bc7.ktx2");
            t.deinit(gpa);
        }
        const load_ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6 / N_ITERS;
        start = nowNs(io);
        for (0..N_ITERS) |_| {
            const img = try Image.read(.{ .io = io, .gpa = gpa, .filepath = "src/Data/Read/BasicArt.png" });
            img.deinit(gpa);
        }
        const png_ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6 / N_ITERS;
        std.debug.print("\nBC7 bake (offline, {} mips)       {d:>8.1} ms\n", .{ tex.levels, bake_ms });
        std.debug.print("load .ktx2 BC7 (file -> upload)   {d:>8.2} ms, {} KB to GPU\n", .{ load_ms, tex.data.len >> 10 });
        std.debug.print("load .png (file -> RGBA8)         {d:>8.2} ms, {} KB to GPU (no mips)\n", .{ png_ms, src.pixels.asBytes().len >> 10 });
    }

    // Batch vs one-by-one
    const path = "src/Data/Read/BasicArt.jpg";
    var paths: [BATCH_N][]const u8 = @splat(path);
    {
        const start = nowNs(io);
        for (paths) |p| {
            const img = try Image.read(.{ .io = io, .gpa = gpa, .filepath = p });
            img.deinit(gpa);
        }
        const ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6;
        std.debug.print("\n{} x Image.read(jpg)        {d:>8.1} ms total, {d:.2} ms/img\n", .{ BATCH_N, ms, ms / BATCH_N });
    }
    {
        const start = nowNs(io);
        const batch = try Image.Batch.load(io, gpa, &paths, .{});
        defer batch.deinit(gpa);
        const ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6;
        std.debug.print("Batch.load({} jpg)            {d:>8.1} ms total, {d:.2} ms/img, 1 alloc of {} MB\n", .{
            BATCH_N, ms, ms / BATCH_N, batch.bytes.len >> 20,
        });
    }
    {
        const start = nowNs(io);
        const batch = try Image.Batch.load(io, gpa, &paths, .{ .threads = 0 });
        defer batch.deinit(gpa);
        const ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1e6;
        std.debug.print("Batch.load({} jpg, threaded)  {d:>8.1} ms total, {d:.2} ms/img\n", .{ BATCH_N, ms, ms / BATCH_N });
    }
}
