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

    const file_len = try file.length(io);
    if (file_len == 0) return error.NoDataInFile;

    const max_cpu_threads = std.Thread.getCpuCount() catch 0;
    const is_single_threaded: bool = @import("builtin").single_threaded or //
        request.n_threads == 0 or //
        max_cpu_threads == 0;
    if (is_single_threaded) {
        var buf: [BUF_LEN]u8 = undefined;
        var reader = file.reader(io, &buf);
        return reader.interface.readAlloc(gpa, file_len);
    }

    const data = try gpa.alloc(u8, file_len);
    errdefer gpa.free(data);

    const n_threads: u64 = @min(UPPER_LIMIT_THREADS, @min(max_cpu_threads, @min(request.n_threads, file_len / BUF_LEN)));
    const chunk_size = file_len / n_threads;

    const work_list = try gpa.alloc(Work, n_threads);
    defer gpa.free(work_list);

    var start: u64 = 0;
    var end: u64 = chunk_size;
    for (0..n_threads - 1) |i| {
        work_list[i] = .{
            .file = file,
            .io = io,
            .start = start,
            .end = end,
            .data = data,
        };
        start = end;
        end = start + chunk_size;
    }
    work_list[n_threads - 1] = .{
        .file = file,
        .io = io,
        .start = start,
        .end = file_len,
        .data = data,
    };

    const threads = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(threads);
    for (0..n_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, readData, .{&work_list[i]});
    }
    for (threads) |t| t.join();

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
