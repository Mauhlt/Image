const std = @import("std");
const Io = std.Io;

const Image = @import("root.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = debug_allocator.allocator();
    defer std.debug.assert(.ok == debug_allocator.deinit());

    // still slower on mt mode - why?
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    const reps: u64 = 10_000;
    const t1 = try timerFn(io, gpa, reps, Image.read, .{ io, gpa, "src/Data/BasicArt.bmp", .{} });
    const t2 = try timerFn(io, gpa, reps, Image.read, .{ io, gpa, "src/Data/BasicArt.bmp", .{ .n_threads = 4 } });
    // what - t2 is slower than t1, t2 is multithreaded?
    std.debug.print("{} - {}\n", .{ t1, t2 });
}

pub fn timerFn(
    io: std.Io,
    gpa: std.mem.Allocator,
    reps: u64,
    comptime func: anytype,
    args: anytype,
) !u64 {
    switch (@typeInfo(@TypeOf(func))) {
        .@"fn" => {},
        else => @compileError("Func must be a fn"),
    }
    const clock: std.Io.Clock = .awake;
    const start = clock.now(io).toMilliseconds();
    var step: u64 = 0;
    for (0..reps) |_| {
        if (@mod(step, 1000) == 0) std.debug.print("{}\n", .{step});
        const value = try @call(.auto, func, args);
        defer gpa.free(value);
        step += 1;
    }
    const end = clock.now(io).toMilliseconds();
    return @intCast(end - start);
}
