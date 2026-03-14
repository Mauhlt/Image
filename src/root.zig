const std = @import("std");
const Image = @import("Formats/Image.zig");
const UPPER_LIMIT_THREADS: u64 = 64;

pub fn format(self: *const @This(), w: *std.Io.Writer) !void {
    try w.print(
        "Image\nDims:\n\tWidth: {}\n\tHeight: {}\n\tDepth: {}\n\tFormat: {t}\n\t",
        .{ self.extent.width, self.extent.height, self.extent.depth, self.pixel_format },
    );
    switch (self.pixels) {
        inline else => |data| {
            const first_pixel = data[0];
            const last_pixel = data[1];
            try w.print("First: {any}\n\t", .{first_pixel});
            try w.print("Last: {any}\n", .{last_pixel});
        }
    }
}

const Work = struct {
    file: std.Io.File,
    io: std.Io,
    start: u64,
    end: u64,
    data: []u8,
    err: ?anyerror = null,
};

const BUF_LEN: u64 = 4 * 1024;

pub const Request = struct {
    n_threads: u8 = 0,
};

/// Uses mt file reader - want to test how much faster mt is than st.
/// Requested Number Of Threads = User request is then limited by buffer size + max # of threads on cpu
pub fn read(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    request: Request,
) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close(io);

    const file_len = file.length(io) catch 0;
    if (file_len == 0) return error.NoDataInFile;

    const max_cpu_threads = std.Thread.getCpuCount() catch 0;
    if (isSingleThreaded(request.n_threads)) {
        var buf: [BUF_LEN]u8 = undefined;
        var reader = file.reader(io, &buf);
        return reader.interface.readAlloc(gpa, file_len);
    }

    var mm = try file.createMemoryMap(io, .{
        .len = file_len,
        .protection = .{ .read = true },
    });
    defer mm.destroy(io);
    try mm.read(io);

    const data: []const u8 = try mm.memory[0..file_len];
    const n_threads: u64 = @reduce(
        .Min,
        @as(@Vector(4, bool), .{
            UPPER_LIMIT_THREADS,
            max_cpu_threads,
            request.n_threads,
            file_len / BUF_LEN,
        }),
    );
    const chunk_size = file_len / n_threads;

    const futures = try gpa.alloc(std.Io.Future(u64), n_threads);
    defer gpa.free(futures);

    for (0..n_threads) |i| {
        const start = i * chunk_size;
        const end = @min(start + chunk_size, file_len);
        futures[i] = io.async(readData, .{data[start..end]});
    }

    return data;
}

fn readData(work: *Work) void {
    var buf: [BUF_LEN]u8 = undefined;
    std.debug.assert(work.start < work.end);
    var offset = work.start;
    var n_bytes_read: u64 = 0;
    while (offset < work.end) {
        const req_bytes = @min(buf.len, work.end - offset);
        n_bytes_read = work.file.readPositionalAll(work.io, buf[0..req_bytes], offset) catch |err| {
            work.err = err;
            return;
        };
        if (n_bytes_read == 0) {
            work.err = error.UnexpectedEOF;
            return;
        }
        // @memcpy(work.data[offset .. offset + n_bytes_read], buf[0..n_bytes_read]);
        offset += n_bytes_read;
    }
}

pub fn read2(io: std.Io, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer file.close();

    const file_len = try file.length(io);
    if (file_len == 0) return error.NoDataInFile;

    var mmap = try file.createMemoryMap(io, .{ .len = 4096 });
    defer mmap.destroy(io);

    try mmap.read(io);
}

fn isSingleThreaded(n_threads: u64) bool {
    const max_cpu_threads = std.Thread.getCpuCount() catch 0;
    return @import("builtin").single_threaded or //
        n_threads == 0 or //
        max_cpu_threads == 0;
}
