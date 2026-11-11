//! Many images stored back to back in ONE pixel allocation.
//!
//! Why this is faster than calling `Image.read` N times:
//!   - 1 growable file buffer is reused for every file (no alloc per file read)
//!   - decoder temporaries come from an arena that is reset, not freed, between images
//!   - all pixels land in a single contiguous buffer (1 alloc; when every image has the
//!     same size the exact total is reserved up front after the first header)
//!   - width/height are stored once when all images share a size (`Shape.uniform`)
//!   - the contiguous buffer can be copied to a GPU staging buffer in one memcpy,
//!     image `i` lives at `offset(i)` (e.g. one layer of a 2D array texture)
const std = @import("std");
const vk = @import("Vulkan");
const Image = @import("root.zig");
const Info = @import("info.zig");
const misc = @import("misc.zig");
const Pixels = @import("Colors/pixels.zig").Pixels;
const PixelTag = @import("Colors/pixels.zig").PixelTag;

const Batch = @This();

tag: PixelTag,
fmt: vk.Format,
bytes: []u8,
shape: Shape,

pub const Entry = struct {
    width: u32,
    height: u32,
    offset: usize,
};

pub const Shape = union(enum) {
    /// every image is `width x height`; image i starts at i * width * height * bpp
    uniform: struct { width: u32, height: u32, count: usize },
    /// sizes differ; one entry per image
    varied: []Entry,
};

pub const LoadOptions = struct {
    path_type: Image.PathType = .cwd,
    dir: std.Io.Dir = undefined,
    /// pixel layout to store; null = layout of the first image.
    /// Images decoded in a different layout are converted.
    tag: ?PixelTag = null,
    /// decoder threads: 1 = this thread only, 0 = one per CPU core
    threads: usize = 1,
};

pub fn len(self: *const Batch) usize {
    return switch (self.shape) {
        .uniform => |u| u.count,
        .varied => |entries| entries.len,
    };
}

pub fn entry(self: *const Batch, i: usize) Entry {
    return switch (self.shape) {
        .uniform => |u| .{
            .width = u.width,
            .height = u.height,
            .offset = i * @as(usize, u.width) * u.height * self.tag.bytesPerPixel(),
        },
        .varied => |entries| entries[i],
    };
}

/// Borrowed view of image `i`. Do NOT call `deinit` on it; the batch owns the memory.
pub fn get(self: *const Batch, i: usize) Image {
    const e = self.entry(i);
    const n = @as(usize, e.width) * e.height * self.tag.bytesPerPixel();
    return .{
        .width = e.width,
        .height = e.height,
        .fmt = self.fmt,
        .pixels = .fromBytes(self.tag, self.bytes[e.offset..][0..n]),
    };
}

pub fn deinit(self: Batch, gpa: std.mem.Allocator) void {
    gpa.free(self.bytes);
    switch (self.shape) {
        .uniform => {},
        .varied => |entries| gpa.free(entries),
    }
}

/// Decodes one image into `dst`, converting to `tag` if the file decodes to another layout.
fn decodeOne(img_tag: Image.ImageTag, scratch: std.mem.Allocator, data: []const u8, inf: Info, tag: PixelTag, dst: []u8) !void {
    if (inf.tag == tag) return Image.decodeInto(img_tag, scratch, data, inf, dst);
    const tmp = try scratch.alloc(u8, try inf.byteLen());
    try Image.decodeInto(img_tag, scratch, data, inf, tmp);
    const converted = try Pixels.fromBytes(inf.tag, tmp).convertV(tag, scratch);
    @memcpy(dst, converted.asBytes());
}

pub fn load(
    io: std.Io,
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    opts: LoadOptions,
) !Batch {
    if (paths.len == 0) return error.EmptyBatch;
    const n_threads = if (opts.threads == 0) std.Thread.getCpuCount() catch 1 else opts.threads;
    if (n_threads > 1 and paths.len > 1) return loadThreaded(io, gpa, paths, opts, @min(n_threads, paths.len));

    var file_buf: std.ArrayList(u8) = .empty;
    defer file_buf.deinit(gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(gpa);
    try entries.ensureTotalCapacity(gpa, paths.len);

    var tag: PixelTag = undefined;
    var fmt: vk.Format = undefined;

    for (paths, 0..) |path, i| {
        defer _ = arena.reset(.retain_capacity);
        const img_tag = try misc.tagFromExt(path);
        var file = try Image.openFile(io, opts.dir, path, opts.path_type);
        defer file.close(io);
        const data = try misc.readFileInto(io, gpa, file, &file_buf);

        const inf = try Image.info(img_tag, data);
        if (i == 0) {
            tag = opts.tag orelse inf.tag;
            fmt = batchFmt(tag, inf);
        }
        const dst_len = try dstLen(inf, tag);
        // first image: reserve exactly enough for N images of this size
        if (i == 0) try bytes.ensureTotalCapacityPrecise(gpa, dst_len * paths.len);
        const offset = bytes.items.len;
        try bytes.resize(gpa, offset + dst_len);
        try decodeOne(img_tag, arena.allocator(), data, inf, tag, bytes.items[offset..][0..dst_len]);
        entries.appendAssumeCapacity(.{ .width = inf.width, .height = inf.height, .offset = offset });
    }
    return finish(gpa, tag, fmt, try bytes.toOwnedSlice(gpa), entries.items);
}

fn batchFmt(tag: PixelTag, first: Info) vk.Format {
    return if (tag == first.tag) first.fmt else Info.fmtFor(tag, std.mem.endsWith(u8, @tagName(first.fmt), "srgb"));
}

fn dstLen(inf: Info, tag: PixelTag) !usize {
    const dst: Info = .{ .width = inf.width, .height = inf.height, .tag = tag, .fmt = .undefined };
    return dst.byteLen();
}

/// Takes ownership of `bytes`; copies `entries` only if sizes vary.
fn finish(gpa: std.mem.Allocator, tag: PixelTag, fmt: vk.Format, bytes: []u8, entries: []const Entry) !Batch {
    errdefer gpa.free(bytes);
    const uniform = for (entries[1..]) |e| {
        if (e.width != entries[0].width or e.height != entries[0].height) break false;
    } else true;
    const shape: Shape = if (uniform) .{ .uniform = .{
        .width = entries[0].width,
        .height = entries[0].height,
        .count = entries.len,
    } } else .{ .varied = try gpa.dupe(Entry, entries) };
    return .{ .tag = tag, .fmt = fmt, .bytes = bytes, .shape = shape };
}

/// Pass 1 (this thread): read every file + parse headers -> exact offsets, ONE allocation.
/// Pass 2 (worker threads): each claims the next image index and decodes into its own slice.
fn loadThreaded(
    io: std.Io,
    gpa: std.mem.Allocator,
    paths: []const []const u8,
    opts: LoadOptions,
    n_threads: usize,
) !Batch {
    var files_arena: std.heap.ArenaAllocator = .init(gpa);
    defer files_arena.deinit();
    const fa = files_arena.allocator();

    const Job = struct { img_tag: Image.ImageTag, data: []const u8, inf: Info };
    const jobs = try fa.alloc(Job, paths.len);
    const entries = try fa.alloc(Entry, paths.len);
    var total: usize = 0;
    var tag: PixelTag = undefined;
    var fmt: vk.Format = undefined;
    for (paths, jobs, entries, 0..) |path, *job, *e, i| {
        const img_tag = try misc.tagFromExt(path);
        var file = try Image.openFile(io, opts.dir, path, opts.path_type);
        defer file.close(io);
        var buf: std.ArrayList(u8) = .empty;
        const data = try misc.readFileInto(io, fa, file, &buf);
        const inf = try Image.info(img_tag, data);
        if (i == 0) {
            tag = opts.tag orelse inf.tag;
            fmt = batchFmt(tag, inf);
        }
        job.* = .{ .img_tag = img_tag, .data = data, .inf = inf };
        e.* = .{ .width = inf.width, .height = inf.height, .offset = total };
        total += try dstLen(inf, tag);
    }

    const bytes = try gpa.alloc(u8, total);
    errdefer gpa.free(bytes);

    const Shared = struct {
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        err: anyerror = undefined,
        jobs: []const Job,
        entries: []const Entry,
        bytes: []u8,
        tag: PixelTag,
        gpa: std.mem.Allocator,

        fn work(sh: *@This()) void {
            var arena: std.heap.ArenaAllocator = .init(sh.gpa);
            defer arena.deinit();
            while (!sh.failed.load(.monotonic)) {
                const i = sh.next.fetchAdd(1, .monotonic);
                if (i >= sh.jobs.len) return;
                const job = sh.jobs[i];
                const n = dstLen(job.inf, sh.tag) catch unreachable; // validated in pass 1
                decodeOne(job.img_tag, arena.allocator(), job.data, job.inf, sh.tag, sh.bytes[sh.entries[i].offset..][0..n]) catch |err| {
                    if (!sh.failed.swap(true, .acq_rel)) sh.err = err;
                    return;
                };
                _ = arena.reset(.retain_capacity);
            }
        }
    };
    var shared: Shared = .{ .jobs = jobs, .entries = entries, .bytes = bytes, .tag = tag, .gpa = gpa };

    const threads = try fa.alloc(std.Thread, n_threads - 1);
    var spawned: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, Shared.work, .{&shared}) catch break;
        spawned += 1;
    }
    shared.work(); // this thread helps too
    for (threads[0..spawned]) |t| t.join();
    if (shared.failed.load(.acquire)) return shared.err;

    return finish(gpa, tag, fmt, bytes, entries);
}

test "Batch - uniform" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const paths = [_][]const u8{
        "src/Data/Read/BasicArt.png",
        "src/Data/Read/BasicArt.tga",
        "src/Data/Read/BasicArt.webp",
        "src/Data/Read/BasicArt.ppm",
    };
    const batch = try load(io, gpa, &paths, .{ .tag = .rgba });
    defer batch.deinit(gpa);
    const threaded_batch = try load(io, gpa, &paths, .{ .tag = .rgba, .threads = 0 });
    defer threaded_batch.deinit(gpa);
    try std.testing.expectEqualSlices(u8, batch.bytes, threaded_batch.bytes);

    try std.testing.expect(batch.shape == .uniform);
    try std.testing.expectEqual(paths.len, batch.len());
    try std.testing.expectEqual(@as(usize, 1536 * 864 * 4 * paths.len), batch.bytes.len);

    const ref = try Image.read(.{ .io = io, .gpa = gpa, .filepath = paths[0] });
    defer ref.deinit(gpa);
    for (0..batch.len()) |i| {
        const view = batch.get(i);
        try Image.expectSimilar(gpa, &ref, &view, .rgba, 0);
    }
}

test "Batch - varied sizes" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const paths = [_][]const u8{
        "src/Data/Read/Gradient.png",
        "src/Data/Read/BasicArt.png",
        "src/Data/Read/Gradient.webp",
    };
    const batch = try load(io, gpa, &paths, .{ .threads = 3 });
    defer batch.deinit(gpa);

    try std.testing.expect(batch.shape == .varied);
    try std.testing.expectEqual(@as(u32, 1536), batch.entry(1).width);
    try std.testing.expectEqual(@as(usize, 67 * 45 * 4), batch.entry(1).offset);
    for (paths, 0..) |path, i| {
        const ref = try Image.read(.{ .io = io, .gpa = gpa, .filepath = path });
        defer ref.deinit(gpa);
        const view = batch.get(i);
        try Image.expectSimilar(gpa, &ref, &view, .rgba, 0);
    }
}
