/// Goals:
/// 1. Create a reader per image type
///     - read file into native header + body
///     - convert to universal image struct
///     - use polymorphism to switch between types
/// 2. Create universal Image struct:
///     - width
///     - height
///     - image data
///     - bit size
/// 3. Create a writer per image type
///     - write img into native headr + body
///     - convert from universal image struct
///     - use polymorphism to switch between types
/// Data Structures:
/// Reader:
///     - parse input arguments
///     - validate filepath
///     - read data
///     - convert data to image structure
/// Writer:
///     - parse input arguments
///     - validate filepath
///     - convert image structure to data
///     - write data
/// Polymorphism:
///     - tagged unions
///     - inline else fn calls
/// Command Line Arguments:
///   executable:
///     - image -r "filepath" - reads file at filepath
///     - image -w "filepath" - writes file at filepath
///     - image -c "filepath" "new filepath" - converts file from one image to another
///     - image -c "filepath" "ext" - converts image at filepath to new format and saves it in same directory
///   module:
///     - const Image = import("Image");
///     - Image.read("");
///     - Image.write("");
///     - Image.convert("filepath", "new_filepath");
const std = @import("std");
const testing = std.testing;
const extractImageFileType = @import("Io/Interface.zig").extractImageFileType;
const ImageFile = @import("Io/Interface.zig").ImageFile;
const BMP = @import("Io/bmp.zig");

pub fn main(init: std.process.Init) !void {

    // allocate buffer
    // var arena = init.arena;
    // const allo = arena.allocator();
    // defer arena.deinit();

    var buffer: [3 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allo = fba.allocator();

    const filepath: []const u8 = "src/Data/BasicArt.bmp";
    if (filepath.len == 0) return error.InvalidFilepath;
    // const image_file_type = try extractImageFileType(filepath);

    const io = init.io;
    var file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const io_reader = &reader.interface;

    // // wastes memory by letting all of them use the same size memory
    // const file_type = switch (image_file_type) {
    //     inline else => @unionInit(ImageFile, @tagName(image_file_type), .{ .hdr = undefined, .body = undefined }),
    // };
    // const data = file_type.read(&reader, &allo);

    const bmp: BMP = try .read(io_reader, &allo);
    std.debug.print("{f}\n", .{bmp});

    // .qoi => try readQoi(&reader.interface),

}
