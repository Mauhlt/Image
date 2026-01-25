const std = @import("std");

const N: comptime_int = 256;
const Freq = [N]u32;

// version 1
pub fn simple(data: []const u8) Freq {
    // assumes # of items < 2^32
    var freqs: Freq = [_]u32{0} ** N;
    for (data) |datum| freqs[datum] += 1;
    return freqs;
}

// version 2
fn simple2(data: []const u8, freq: *Freq, done: *bool) void {
    for (data) |datum| freq[datum] += 1;
    done.* = true;
}

pub fn threaded(data: []const u8) !Freq {
    // fastest
    const total_threads = 16;
    var threads: [total_threads]std.Thread = undefined;
    var freqs: [total_threads]Freq = @bitCast([_]u32{0} ** (N * total_threads));
    var done = [_]bool{true} ** total_threads;

    const num_threads = @min((std.Thread.getCpuCount() catch 2) - 1, total_threads);
    const max_data_per_thread: usize = @divTrunc(data.len, num_threads);

    var start: usize = 0;
    var end: usize = max_data_per_thread;
    for (0..num_threads - 1) |i| {
        threads[i] = std.Thread.spawn(
            .{},
            simple2,
            .{ data[start..end], &freqs[i], &done[i] },
        ) catch unreachable;
        start = end;
        end += max_data_per_thread;
    }

    threads[num_threads - 1] = std.Thread.spawn(
        .{},
        simple2,
        .{ data[start..data.len], &freqs[num_threads - 1], &done[num_threads - 1] },
    ) catch unreachable;

    // let threads fly
    inline for (0..num_threads) |i| threads[i].detach();
    while (@reduce(.And, @as(@Vector(total_threads, bool), done)) != true) {}

    // combine results - sum across
    for (1..num_threads) |i| {
        // var j: usize = 0;
        // while (j + 64 < N) : (j += 64) {
        //     freqs[0][j .. j + 64].* = @as(@Vector(64, u32), freqs[i][j .. j + 64]) +
        //         @as(@Vector(64, u32), freqs[0][j .. j + 64]);
        // }

        // for (freq, 0..) |f, i| {
        //     freqs[0][i] += f;
        // }
    }

    return freqs[0];
}

// version 3
fn simple3(data: []const u8, freq: *Freq) void {
    const len = data.len;
    var i: usize = 0;
    while (i + 64 < len) : (i += 64) {
        const vec_data: @Vector(64, u8) = data[i..][0..64].*;
        inline for (0..freq.len) |j| {
            const splat_data: @Vector(64, u8) = @splat(j);
            freq[j] += @as(u32, @popCount(@as(u64, @bitCast(vec_data == splat_data))));
        }
    } else {
        var new_data = [_]u8{0} ** 64;
        @memcpy(new_data[0 .. data.len - i], data[i..data.len]);
        const vec_data: @Vector(64, u8) = new_data;
        inline for (0..freq.len) |j| {
            const splat_data: @Vector(64, u8) = @splat(j);
            freq[j] += @as(u32, @popCount(@as(u64, @bitCast(vec_data == splat_data))));
        }
    }
}

pub fn threaded_simd(data: []const u8) !Freq {
    const num_threads = 8;
    var threads: [num_threads]std.Thread = undefined;
    var freqs: [num_threads]Freq = @bitCast([_]u32{0} ** (256 * num_threads));
    const max_data_per_thread: usize = @divTrunc(data.len, num_threads);

    var start: usize = 0;
    var end: usize = max_data_per_thread;
    for (0..num_threads - 1) |i| {
        threads[i] = std.Thread.spawn(
            .{},
            simple3,
            .{ data[start..end], &freqs[i] },
        ) catch unreachable;
        start = end;
        end += max_data_per_thread;
    }

    threads[num_threads - 1] = std.Thread.spawn(
        .{},
        simple3,
        .{ data[start..data.len], &freqs[num_threads - 1] },
    ) catch unreachable;

    for (0..num_threads) |i| threads[i].join();

    // is this the slow part? - no
    for (0..256) |i| {
        var f_values = [_]u32{0} ** num_threads;
        inline for (0..num_threads) |j| f_values[j] = freqs[j][i];
        const vec_freqs: @Vector(num_threads, u32) = f_values;
        freqs[0][i] = @reduce(.Add, vec_freqs);
    }

    return freqs[0];
}

// version 4

const Input = enum {
    simple,
    threaded,
    threaded_simd,
};

fn timer(input: Input, data: []const u8, n_reps: usize) !Freq {
    const start: i128 = std.time.nanoTimestamp();

    for (0..n_reps - 1) |_| {
        _ = switch (input) {
            .simple => simple(data),
            .threaded => try threaded(data),
            .threaded_simd => try threaded_simd(data),
        };
    }
    const freqs = switch (input) {
        .simple => simple(data),
        .threaded => try threaded(data),
        .threaded_simd => try threaded_simd(data),
    };

    const end: i128 = std.time.nanoTimestamp();

    const ns_pers = [_]comptime_int{
        std.time.ns_per_min,
        std.time.ns_per_s,
        std.time.ns_per_ms,
        std.time.ns_per_us,
    };
    var time_sects = [_]i128{0} ** (ns_pers.len + 1);

    var diff = @divTrunc((end - start), @as(i128, n_reps)); // avg
    inline for (ns_pers, 0..) |ns_per, i| {
        time_sects[i] = @divTrunc(diff, ns_per);
        diff -= (time_sects[i] * ns_per);
    }
    time_sects[time_sects.len - 1] = diff;

    const end_strs = [_][]const u8{ "min", "sec", "ms", "us", "ns" };
    for (end_strs, 0..) |end_str, i| {
        std.debug.print("{}{s} ", .{ time_sects[i], end_str });
    }
    std.debug.print("\n", .{});

    return freqs;
}

// test "Count Frequencies" {
//     const allo = std.testing.allocator;
//     // Upper Size Limits: Image Size * 2, 2 = worst case scenario for run length encoding
//     // Image Size:
//     //   Expected Load: 1920 * 1080 * 4 (~8 Mb)
//     //   High Load: 3840 * 2160 * 4 (~32 Mb)
//     //   Extremely High Load: 7680 * 4320 * 4 (~128 Mb)
//     //
//     const limit: usize = 1920 * 1080;
//     var data: []u8 = try allo.alloc(u8, limit);
//     defer allo.free(data);
//
//     const time: u64 = @intCast(@abs(std.time.milliTimestamp()));
//     var r = std.Random.DefaultPrng.init(time);
//     const rand = r.random();
//
//     for (0..data.len) |i| {
//         const rand_num = rand.intRangeAtMost(u8, 0, 255);
//         data[i] = rand_num;
//     }
//
//     const n_reps: i128 = 1; // 1_000, 10_000
//     const f1 = try timer(.simple, data, n_reps);
//     const f2 = try timer(.threaded, data, n_reps); // fastest = ~4-5x faster
//     const f3 = try timer(.threaded_simd, data, n_reps);
//
//     // ensure that each freq fn is correct
//     for (f1, f2, f3) |uno, dos, tres| {
//         try std.testing.expect(uno == dos and dos == tres);
//     }
// }
