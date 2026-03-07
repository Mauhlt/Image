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
const ImageFile = @import("Io/ImageLoader.zig").ImageFile;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const filepath: []const u8 = "src/Data/BasicArt.bmp";

    var buffer: [2 * 1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allo = fba.allocator();
    const image = ImageFile.read(io, &allo, filepath);
    std.debug.print("Image: {any}\n", .{image});
}
