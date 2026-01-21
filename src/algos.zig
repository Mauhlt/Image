const std = @import("std");
const expectEqual = std.testing.expectEqual;

// image reperesentations matter:
// bool, int, float, complex
// is data linear or matrix
// does it have width, height, depth (videos)

pub fn runLengthEncodingV1(
    comptime T: type,
    data: []const T,
    buffer: []T,
) ![]const T {
    // first value = data
    // second value = amt of data
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Fn only accepts ints."),
    }
    const sign = @typeInfo(T).int.signedness;
    const is_smaller = @typeInfo(T).int.bits < 64;
    var i: usize = 0;
    var k: usize = 0;
    const len = data.len;
    while (i < len) : (i += 1) {
        var j: usize = 1;
        while (i + j < data.len and data[i + j] == data[i]) : (j += 1) {}
        buffer[k] = data[i];
        i += j - 1;
        k += 1;
        if (k >= buffer.len) return error.FoundTooManyUniqueSymbols;
        switch (sign) {
            .signed => buffer[k] = @intCast(j),
            .unsigned => switch (is_smaller) {
                true => buffer[k] = @truncate(j),
                false => buffer[k] = j,
            }
        }
        k += 1;
        if (k >= buffer.len) return error.FoundTooManyUniqueSymbols;
    }
    return buffer[0..k];
}

pub fn runLengthDecodingV1(
    comptime T: type,
    data: []const T,
    buffer: []T,
) ![]const T {
    // performs run length decoding
    // assumes length is greater than 0
    // safety check: pre-compute full length
    var i: usize = 1;
    const len = data.len;
    var total_len: usize = 0;
    while (i < len) : (i += 2) {
        switch (@typeInfo(T).int.signedness) {
            .signed => total_len += @intCast(data[i]),
            .unsigned => total_len += data[i],
        }
    }
    if (total_len > buffer.len) return error.BufferTooSmall;
    // decode
    var k: usize = 0;
    i = 0;
    while (i < len) {
        var curr_len: usize = 0;
        switch (@typeInfo(T).int.signedness) {
            .signed => curr_len = @intCast(data[i + 1]),
            .unsigned => curr_len = data[i + 1],
        }
        @memset(buffer[k .. k + curr_len], data[i]);
        k += curr_len;
        i += 2;
    }
    return buffer[0..k];
}

pub fn runLengthEncodingV2(
    comptime T: type,
    data: []const T,
    buffer: []T,
) ![]const T {
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Fn only accepts ints."),
    }
    var i: usize = 0;
    var k: usize = 0;
    var matches: u64 = @bitCast(@as(@Vector(64, T), data[i..][0..64].*) == @as(@Vector(64, T), data[i + 1 ..][0..64].*));
    matches = ~matches;
    var total_matches: usize = 0;
    var n_matches: usize = 0;
    while (matches > 0) {
        n_matches = @ctz(matches) + 1;
        buffer[k] = data[i];
        k += 1;
        buffer[k] = switch (@typeInfo(T).int.signedness) {
            .signed => @intCast(n_matches),
            .unsigned => n_matches,
        };
        k += 1;
        matches = matches >> @truncate(n_matches);
        i += n_matches;
        total_matches += n_matches;
    }
    if (total_matches != 64) {
        buffer[k] = data[i];
        k += 1;
        const diff = 64 - total_matches + 1;
        buffer[k] = switch (@typeInfo(T).int.signedness) {
            .signed => @intCast(diff),
            .unsigned => diff,
        };
        k += 1;
    }
    return buffer[0..k];
}

test "Run Length Encoding/Decoding" {
    // Encoding
    const T: type = i16;
    const data = [64]T{
        140, -14, -14, -3, -1, 0, 0, 0,
        -10, -8,  14,  4,  2,  0, 0, 0,
        14,  -4,  -4,  -1, -1, 0, 0, 0,
        0,   -2,  -2,  0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
    };
    var buffer = [_]T{0} ** 64;
    const encoded_data = try runLengthEncodingV1(@TypeOf(data[0]), &data, &buffer);
    const expected_encoded_data = [_]T{ 140, 1, -14, 2, -3, 1, -1, 1, 0, 3, -10, 1, -8, 1, 14, 1, 4, 1, 2, 1, 0, 3, 14, 1, -4, 2, -1, 2, 0, 4, -2, 2, 0, 37 };
    for (encoded_data, expected_encoded_data) |ed, eed| try expectEqual(eed, ed);
    var buffer1 = [_]T{0} ** 64;
    const decode_data = try runLengthDecodingV1(@TypeOf(encoded_data[0]), encoded_data, &buffer1);
    for (data, decode_data) |d, dd| try expectEqual(d, dd);

    const data2 = [_]u8{ 'A', 'A', 'A', 'A', 'B', 'B', 'B', 'C', 'C', 'D', 'A', 'A' };
    var buffer2 = [_]u8{0} ** 64;
    const encoded_data_2 = try runLengthEncodingV1(@TypeOf(data2[0]), &data2, &buffer2);
    const expected_encoded_data_2 = [_]u8{ 'A', 4, 'B', 3, 'C', 2, 'D', 1, 'A', 2 };
    for (expected_encoded_data_2, encoded_data_2) |eed, ed| try expectEqual(eed, ed);
    var buffer3 = [_]u8{0} ** 64;
    const decode_data_2 = try runLengthDecodingV1(@TypeOf(encoded_data_2[0]), encoded_data_2, &buffer3);
    for (data2, decode_data_2) |d, dd| try expectEqual(d, dd);

    // run length encoding v2
    const data3 = [65]i16{
        140, -14, -14, -3, -1, 0, 0, 0,
        -10, -8,  14,  4,  2,  0, 0, 0,
        14,  -4,  -4,  -1, -1, 0, 0, 0,
        0,   -2,  -2,  0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,   0,   0,   0,  0,  0, 0, 0,
        0,
    };
    var buffer4 = [_]i16{0} ** 64;
    const output = try runLengthEncodingV2(@TypeOf(data3[0]), &data3, &buffer4);
    const expected_output = [_]i16{ 140, 1, -14, 2, -3, 1, -1, 1, 0, 3, -10, 1, -8, 1, 14, 1, 4, 1, 2, 1, 0, 3, 14, 1, -4, 2, -1, 2, 0, 4, -2, 2, 0, 38 };
    var i: usize = 0;
    while (i < output.len) : (i += 2) {
        try std.testing.expectEqual(output[i], expected_output[i]);
        try std.testing.expectEqual(output[i + 1], expected_output[i + 1]);
    }
}

pub fn zigZag() void {
    // 1. go right
    // 2. go downleft until left col or bot row
    // 3a. if bot row, go right
    // 3b. if left col, go down
    // 4. go upright until top row or right col
    // 5a. if top row, go right
    // 5b. if right col, go down
    // 6. if row 7, col 7, break
    // works!
    // for optimization: store indices as an array instead

    var i: usize = 0; // inc from [0-63]
    var s: SubIndex = .{ .row = 0, .col = 0 }; // guaranteed at top left
    var j: usize = s.subindex2Index(); // current pixel in 8x8 block = should be 0

    outer: switch (ZigZagDir.right) {
        .upright => {
            i += 1;
            // list_of_actions[i] = .upright;
            s.row -= 1;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .right;
            } else if (s.col == 7) {
                continue :outer .down;
            } else {
                continue :outer .upright;
            }
            unreachable;
        },
        .right => {
            i += 1;
            // list_of_actions[i] = .right;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .downleft;
            } else if (s.row == 7 and s.col != 7) {
                continue :outer .upright;
            } else break :outer;
            unreachable;
        },
        .downleft => {
            i += 1;
            // list_of_actions[i] = .downleft;
            s.row += 1;
            s.col -= 1;
            j = s.subindex2Index();
            if (s.row == 7) {
                continue :outer .right;
            } else if (s.col == 0) {
                continue :outer .down;
            } else {
                continue :outer .downleft;
            }
            unreachable;
        },
        .down => {
            i += 1;
            // list_of_actions[i] = .down;
            s.row += 1;
            j = s.subindex2Index();
            if (s.col == 0) {
                continue :outer .upright;
            } else if (s.col == 7) {
                continue :outer .downleft;
            }
            unreachable;
        },
        .up, .left => unreachable,
    }
}

pub fn undoZigZag() void {
    // 1. go left
    // 2. go upright until top row or right col
    // 3a. if top row, go left
    // 3b. if right col, go up
    // 4. go downleft until left col or bot row
    // 5a. if left col, go up
    // 5b. if bot row, go left
    // 6. if row 0, col 0, break!
    // works!
    // for optimization: store indices as an array instead

    var i: usize = 63; // inc from [63-0]
    var s: SubIndex = .{ .row = 7, .col = 7 }; // guaranteed at top left
    var j: usize = s.subindex2Index(); // current pixel in 8x8 block = should be 0

    outer: switch (ZigZagDir.left) {
        .upright => {
            i -= 1;
            // list_of_actions[i] = .upright;
            s.row -= 1;
            s.col += 1;
            j = s.subindex2Index();
            if (s.row == 0) {
                continue :outer .left;
            } else if (s.col == 7) {
                continue :outer .up;
            } else {
                continue :outer .upright;
            }
            unreachable;
        },
        .left => {
            i -= 1;
            // list_of_actions[i] = .right;
            s.col -= 1;
            j = s.subindex2Index();
            if (s.row == 7) {
                continue :outer .upright;
            } else if (s.row == 0 and s.col != 0) {
                continue :outer .downleft;
            } else break :outer;
            unreachable;
        },
        .downleft => {
            i -= 1;
            // list_of_actions[i] = .downleft;
            s.row += 1;
            s.col -= 1;
            j = s.subIndex2Index();
            if (s.row == 7) {
                continue :outer .left;
            } else if (s.col == 0) {
                continue :outer .up;
            } else {
                continue :outer .downleft;
            }
            unreachable;
        },
        .up => {
            i -= 1;
            // list_of_actions[i] = .down;
            s.row -= 1;
            j = s.subIndex2Index();
            if (s.col == 7) {
                continue :outer .downleft;
            } else if (s.col == 0) {
                continue :outer .upright;
            }
            unreachable;
        },
        .down, .right => unreachable,
    }
}

const ZigZagDir = enum(u8) {
    upright,
    right,
    downleft,
    down,
    up,
    left,
};

const SubIndex = struct {
    row: usize = 0,
    col: usize = 0,

    fn subIndex2Index(s: *const SubIndex) usize {
        return s.row * 8 + s.col;
    }
};

fn index2SubIndex(i: u8) SubIndex {
    const col = @mod(i, 8);
    const row = (i - col) / 8; // need checks here
    return .{
        .row = row,
        .col = col,
    };
}

test "Sub 2 Index or Index 2 Sub" {
    // index2Subindex(i: u8);
}

fn computeNumberOfUniques(comptime T: type, data: []const T) usize {
    // assumes:
    //   data is sorted
    //   0 <= data.len < 2^32
    if (data.len < 2) return data.len;
    var n_uniques: usize = 1;
    for (data[0 .. data.len - 1], data[1..data.len]) |d1, d2| {
        n_uniques += @intFromBool(d1 != d2);
    }
    return n_uniques;
}

fn computeFrequenciesIndex(comptime T: type, data: []T, buffer: []T) !void {
    // assumes:
    //  data is unsorted
    //  0 <= datum <= buffer.len
    //  data = key = index into buffer
    //  count = freq = value stored in buffer at that index
    //  assumes buffer initialized as an array of 0s
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Only accepts ints or unsigned ints."),
    }
    for (data) |datum| {
        if (datum < 0) return error.IndexOutOfBounds;
        if (datum >= buffer.len) return error.IndexOutOfBounds;
        buffer[datum] += 1;
    }
}

fn computeFrequenciesBuffer(
    comptime T: type,
    data: []T,
    symbols_buffer: []T,
    count_buffer: []usize,
) !void {
    // assumes:
    //   data is sorted
    //   0 < data.len < 2^32
    //   symbols buffer + count buffer = list of 0s
    // computes frequencies of each symbol using a buffer
    const n_uniques = computeNumberOfUniques(T, data);
    if (n_uniques > symbols_buffer.len or n_uniques > count_buffer.len) return error.NumUniquesGTBufferLen;
    if (n_uniques == 0) return;
    symbols_buffer[0] = data[0];
    count_buffer[0] = 1;
    var i: usize = 0;
    for (data[0 .. data.len - 1], data[1..data.len]) |d1, d2| {
        if (d1 != d2) {
            i += 1;
            symbols_buffer[i] = d2;
            count_buffer[i] = 1;
        } else {
            count_buffer[i] += 1;
        }
    }
}

fn createFrequenciesStruct(comptime T: type) type {
    switch (@typeInfo(T)) {
        .int => {},
        else => @compileError("Incorrect input type."),
    }

    return struct {
        symbols: []T,
        count: []T,

        pub fn init(allo: std.mem.Allocator, n: usize) !@This() {
            var symbols = try allo.alloc(T, n);
            @memset(symbols[0..n], 0);
            var count = try allo.alloc(T, n);
            @memset(count[0..n], 0);
            return .{
                .symbols = symbols,
                .count = count,
            };
        }

        pub fn deinit(self: *const @This(), allo: std.mem.Allocator) void {
            allo.free(self.symbols);
            allo.free(self.count);
        }
    };
}

fn computeFrequenciesAllo(
    comptime T: type,
    allo: std.mem.Allocator,
    data: []const T,
) !createFrequenciesStruct(T) {
    // assumes:
    //   data is sorted
    //   0 <= data.len < 2^32
    // compute frequencies of each symbol using an arraylist
    // sort = O(nlog(n))
    const n_uniques = computeNumberOfUniques(T, data);
    if (n_uniques == 0) {
        var freqs: createFrequenciesStruct(T) = try .init(allo, 1);
        freqs.count[0] = 0;
        return freqs;
    }
    const freqs: createFrequenciesStruct(T) = try .init(allo, n_uniques);
    freqs.symbols[0] = data[0];
    freqs.count[0] = 1;
    var i: usize = 0;
    for (data[0 .. data.len - 1], data[1..data.len]) |d1, d2| {
        if (d1 != d2) {
            i += 1;
            freqs.symbols[i] = d2;
            freqs.count[i] = 1;
        } else {
            freqs.count[i] += 1;
        }
    }
    return freqs;
}

fn computeFrequenciesMapAllo(
    comptime T: type,
    allo: std.mem.Allocator,
    data: []const T,
) !std.AutoArrayHashMap(T, usize) {
    // assumes:
    //   0 <= data.len < 2^32
    // map = O(1) insert
    const n_uniques = computeNumberOfUniques(T, data);
    var maps: std.AutoArrayHashMap(T, usize) = .init(allo);
    if (n_uniques == 0) return maps;
    for (data) |d| {
        const gp = try maps.getOrPut(d);
        if (gp.found_existing) {
            gp.value_ptr.* += 1;
        } else {
            try maps.put(d, 1);
        }
    }
    return maps;
}

// fn createNode(comptime T: type) type {
//     return struct {
//         freq: usize = 0,
//         sym: ?T = null,
//         left: ?*@This() = null,
//         right: ?*@This() = null,
//     };
// }
//
// fn buildHuffmanTree(
//     comptime T: type,
//     allo: std.mem.Allocator,
//     data: []const T,
// ) !*createNode(T) {
//     // assumptions:
//     //   data is not sorted
//     //   0 < data.len < 2^32; avg = 1920x1080
//     // steps:
//     //  - compute freqs
//     //  - sort data
//     //  - create nodes
//     //  - return tree
//
//     const Node = createNode(T);
//
//     var freqs = try computeFrequenciesMapAllo(T, allo, data);
//     defer freqs.deinit();
//
//     const Cmp = struct {
//         fn lessThan(_: void, a: *Node, b: *Node) bool {
//             return a.freq < b.freq;
//         }
//     };
//
//     var pq = std.PriorityQueue(*Node, void, Cmp.lessThan).init(allo, {});
//     defer pq.deinit();
//
//     // push leaves
//     for (freqs.values(), freqs.keys()) |freq, sym| {
//         if (freq == 0) continue;
//         const leaf = try allo.create(Node);
//         leaf.* = Node{
//             .freq = freq,
//             .sym = sym,
//             .left = null,
//             .right = null,
//         };
//         try pq.add(leaf);
//     }
//
//     // edge case = just use single bit 0
//     if (pq.count() == 1) return pq.remove();
//
//     // merge until 1 root remains
//     while (pq.count() > 1) {
//         const a = pq.remove();
//         const b = pq.remove();
//
//         const parent = try allo.create(Node);
//         parent.* = .{
//             .freq = a.freq + b.freq,
//             .sym = null,
//             .left = a,
//             .right = b,
//         };
//         try pq.add(parent);
//     }
//
//     return pq.remove(); // return node
// }
//
// fn buildHuffmanCodes(comptime T: type, allo: std.mem.Allocator, node: *createNode(T), prefix: []u8, codes: [][]u8) !void {
//     // why store prefix data as u8 instead of as u32s + every combination?
//     if (node.sym) |s| {
//         codes[s] = try allo.dupe(u8, prefix);
//         return;
//     }
//
//     // left = prefix + "0"
//     var left = try allo.alloc(u8, prefix.len + 1);
//     @memcpy(left[0..prefix.len], prefix);
//     left[prefix.len] = '0';
//
//     // right = prefix + "1"
//     var right = try allo.alloc(u8, prefix.len + 1);
//     @memcpy(right[0..prefix.len], prefix);
//     right[prefix.len] = '1';
//
//     try buildHuffmanCodes(T, allo, node.left.?, left, codes);
//     try buildHuffmanCodes(T, allo, node.right.?, right, codes);
//
//     allo.free(left);
//     allo.free(right);
// }
//
// test "Test Huffman Encoding" {
//     const data: []const u8 = "HelloWorld";
//     // sort
//     const allo = std.testing.allocator;
//     const new_data = try allo.dupe(u8, data);
//     defer allo.free(new_data);
//     std.mem.sort(u8, new_data, {}, comptime std.sort.asc(u8));
//     // compute uniques
//     const n_uniques = computeNumberOfUniques(@TypeOf(new_data[0]), new_data);
//     try std.testing.expectEqual(7, n_uniques);
//     // huffman encoding
//     const node: createNode(@TypeOf(data[0])) = try buildHuffmanTree(@TypeOf(data[0]), allo, data);
//     allo.destroy(node);
// }

// version 2
const Node = struct {
    leaf: u8,
    branch: struct {
        left: usize,
        right: usize,
    },
};

const FreqCountedNode = struct {
    count: u64,
    node: usize,
};

fn freqCountedNodePriority(_: void, a: @This(), b: @This()) std.math.Order {
    return std.math.order(a.count, b.count);
}

const FreqCountedNode = struct {
    count: u64,
    node: usize,
};

const HuffmanTable = struct {
    nodes: std.ArrayList(Node),

    pub fn init(allo: std.mem.Allocator, freqs: *const Freqs) !@This() {
        var nodes: std.ArrayList(Node) = try .initCapacity(allo, 4);

        var queue = std.PriorityQueue(FreqCountedNode, void, FreqCountedNode.freqCountedPriority);

        for (freqs, 0..) |freq, i| {
            if (freq == 0) continue;
            try nodes.append(allo, .{
                .count = freq,
                .data = Node.Data{ .leaf = @truncate(i) },
            });
            try queue.add(FreqCountedNode{
                .count = freq,
                .node = i,
            });
        }

        while (queue.count() > 1) {
            const left = queue.remove();
            const right = queue.remove();

            try nodes.append(.{
                .count = left.count + right.count,
                .data = .{
                    .left = left.node,
                    .right = right.node,
                },
            });

            try queue.add(FreqCountedNode{
                .count = left.count + right.count,
                .node = nodes.items.len - 1,
            });
        }

        // now # of items = 1
        var root = queue.remove();

        return .{
            .nodes = nodes,
        };
    }

    pub fn deinit(self: *@This(), allo: std.mem.Allocator) void {
        self.nodes.deinit(allo);
    }
};

const Freqs = [256]u32;

fn countCharFreqs(data: []const u8) Freqs {
    // assumes image data is a u8
    var counts = [_]u32{0} ** 256;
    for (data) |datum| counts[datum] += 1;
    return counts;
}

fn printCharFreqs(freqs: *const Freqs) void {
    for (freqs, 0..) |freq, i| {
        if (freq == 0) continue;
        const ch: u8 = @truncate(i);
        std.debug.print("{c}: {}\n", .{ ch, freq });
    }
}

test "Test Huffman Encoding Using Arrays" {
    const allo = std.testing.allocator;
    const data = "aaaaaasdf";

    const freqs = countCharFreqs(data);
    printCharFreqs(&freqs);

    var table = try HuffmanTable.init(allo, &freqs);
    defer table.deinit(allo);
}
