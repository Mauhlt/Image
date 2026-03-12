const std = @import("std");
const Image = @import("Formats/Image.zig");

/// Fns
fn fromExt(filepath: []const u8) !ImageFile {
    if (filepath.len == 0) return error.InvalidFilepath;
    const ext = std.fs.path.extension(filepath)[1..];
    return std.meta.stringToEnum(ImageFileEnum, ext) orelse
        MapImageExtToImageFileEnum.get(ext) orelse
        error.UnsupportedImageFileExt;
}

/// 1. identifies file type with tagged union
/// 2. switches on tagged union to call correct reader
/// 3. all files return an image
/// 4. is there a way to read the data in the format i want
pub fn read(
    io: std.Io,
    gpa: std.mem.Allocator,
    filepath: []const u8,
) !@This() {
    const file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const io_reader = &reader.interface;

    const image_file_enum = try fromExt(filepath);
    return switch (image_file_enum) {
        .bmp => BMP.read(gpa, io_reader),
        .png => PNG.read(io_reader, gpa),
    };
}

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
