const std = @import("std");
const Image = @import("Image.zig").Image2D;
const ConstImage = @import("Image.zig").ConstImage2D;

/// Read:
///   reader: struct that contains a fn called read with a specific signature - validated at compile time
///   r: std.Io.Reader: interface to read the data
///   img: contains data in a mutable structure to ensure what is returned is modifiable.
pub fn read(reader: anytype, r: *std.Io.Reader, abs_filepath: []const u8) !Image {
    if (@typeInfo(reader) != .pointer) @compileError("Format must be a ptr.");
    if (@typeInfo(reader).pointer.size != .one) @compileError("Format must be a single item pointer.");
    const base = @typeInfo(@typeInfo(reader).pointer.child);
    if (@typeInfo(@typeInfo(reader).pointer.child) != .@"struct") @compileError("Format child must be a struct");
    try hasValidFn(base.@"struct", "read", "fn () !void");
    return reader.read(r, abs_filepath);
}

/// Write:
///  writer: struct that contains a fn called write with a specific signature - validated at compile time
///  w: std.Io.Writer: interface to write the data
///  img: ConstImage, contains constant data to ensure immutability as its written
pub fn write(writer: anytype, w: *std.Io.Writer, img: ConstImage) !void {
    if (@typeInfo(writer) != .pointer) @compileError("Format must be a ptr.");
    if (@typeInfo(writer).pointer.size != .one) @compileError("Format must be a single item pointer.");
    const base = @typeInfo(@typeInfo(writer).pointer.child);
    if (@typeInfo(@typeInfo(writer).pointer.child) != .@"struct") @compileError("Format child must be a struct");
    try hasValidFn(base.@"struct", "write", "fn () !void");
    try writer.write(w, img);
}

fn hasValidFn(
    my_struct: type,
    fn_name: []const u8,
    fn_sig: []const u8,
) !void {
    switch (@typeInfo(my_struct)) {
        .@"struct" => {},
        else => @compileError("Only accepts structs."),
    }
    var has_fn: bool = false;
    var has_fn_sig: bool = false;
    const decls = @typeInfo(my_struct).@"struct".decls;
    outer: for (decls) |decl| {
        if (std.mem.eql(u8, fn_name, decl.name)) {
            has_fn = true;
            if (std.mem.eql(u8, fn_sig, decl)) {
                has_fn_sig = true;
                break :outer;
            }
        }
    }
    if (!has_fn) @compileError("Struct does not implement write fn.");
    if (!has_fn_sig) @compileError("Struct fn does not have correct write fn.");
}

pub const Error = error{
    ReadFailed,
    EndOfstream,
    WriteFailed,
};
