const std = @import("std");
const Image = @import("Formats/Image.zig");
const UPPER_LIMIT_THREADS: u64 = 64;

/// Fns
// fn fromExt(filepath: []const u8) !ImageFile {
//     if (filepath.len == 0) return error.InvalidFilepath;
//     const ext = std.fs.path.extension(filepath)[1..];
//     return std.meta.stringToEnum(ImageFile, ext) orelse
//         MapImageExtToImageFileEnum.get(ext) orelse
//         error.UnsupportedImageFileExt;
// }

/// 1. identifies file type with tagged union
/// 2. switches on tagged union to call correct reader
/// 3. all files return an image
/// 4. is there a way to read the data in the format i want
// pub fn read(
//     io: std.Io,
//     gpa: std.mem.Allocator,
//     filepath: []const u8,
// ) !@This() {
//     const file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
//     defer file.close(io);
//
//     var read_buffer: [4096]u8 = undefined;
//     var reader = file.reader(io, &read_buffer);
//     const io_reader = &reader.interface;
//
//     const image_file_enum = try fromExt(filepath);
//     return switch (image_file_enum) {
//         .bmp => BMP.read(gpa, io_reader),
//         .png => PNG.read(io_reader, gpa),
//     };
// }

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

const Request = struct {
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

    const data = try gpa.alloc(u8, file_len);
    defer gpa.free(data);

    const max_threads = std.Thread.getCpuCount() catch 0;
    const is_single_threaded: bool = @import("builtin").single_threaded or //
        request.n_threads == 0 or //
        max_threads == 0;
    if (is_single_threaded) {
        var buf: [BUF_LEN]u8 = undefined;
        var reader = file.reader(io, &buf);
        return reader.interface.readAlloc(gpa, file_len);
    }
    const n_threads: u64 = @min(UPPER_LIMIT_THREADS, @min(max_threads, @min(request.n_threads, file_len / BUF_LEN)));
    const chunk_size = file_len / n_threads;

    const work_list = try gpa.alloc(Work, n_threads);
    defer gpa.free(work_list);

    var start: u64 = 0;
    var end: u64 = chunk_size;
    std.debug.print("# of Threads: {}\n", .{n_threads - 1});
    for (0..n_threads - 1) |i| {
        work_list[i] = .{
            .file = file,
            .io = io,
            .start = start,
            .end = end,
            .data = data,
        };
        std.debug.print("Inside Start: {}\n", .{start});
        std.debug.print("Inside End: {}\n", .{end});
        start = end;
        end = start + chunk_size;
    }
    std.debug.print("Outside Start: {}\n", .{start});
    std.debug.print("Outside End: {}\n", .{end});
    work_list[n_threads - 1] = .{
        .file = file,
        .io = io,
        .start = start,
        .end = file_len,
        .data = data,
    };

    std.debug.print("File Length: {}\n", .{file_len});
    const threads = try gpa.alloc(std.Thread, n_threads);
    defer gpa.free(threads);

    var is_complete = [_]bool{true} ** 64;
    for (0..n_threads) |i| is_complete[i] = false;

    for (0..n_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, readData, .{ &work_list[i], &is_complete[i], i });
        threads[i].detach();
    }

    // spins until complete - should be event loop = reduces cpu load
    while (@reduce(.Or, @as(@Vector(64, bool), is_complete)) != true) {}
    for (work_list) |w| if (w.err) |err| return err;

    return data;
}

fn readData(work: *Work, is_complete: *bool, idx: u64) void {
    var buf: [BUF_LEN]u8 = undefined;
    if (work.start > work.end) {
        std.debug.print("{}: {} - {}\n", .{ idx, work.start, work.end });
        is_complete.* = true;
        return;
    }
    std.debug.assert(work.start < work.end);
    // std.debug.assert(work.data.len >= work.start and work.data.len >= work.end);
    var offset = work.start;
    var n_bytes_read: u64 = 0;
    while (offset < work.end) {
        const req_bytes = @min(buf.len, work.end - offset);
        n_bytes_read = work.file.readPositionalAll(work.io, buf[0..req_bytes], offset) catch |err| {
            work.err = err;
            is_complete.* = true;
            return;
        };
        if (n_bytes_read == 0) {
            work.err = error.UnexpectedEOF;
            is_complete.* = true;
            return;
        }
        std.debug.assert(work.data.len > offset and work.data.len > offset + n_bytes_read);
        @memcpy(work.data[offset .. offset + n_bytes_read], buf[0..n_bytes_read]);
        offset += n_bytes_read;
    }
    is_complete.* = true;
}
