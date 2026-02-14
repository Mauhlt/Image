const std = @import("std");
const countFreqs = @import("countFreqs.zig").countFrequenciesThreaded;
// assumptions:
//  - standard image: 1920 x 1080 x 4
//  - data = u8
//  - block size = 8x8 (64 total) = speed up decoding
//  - 1 tree = speeds up encoding

const Bin = struct { // total size: 3 bytes
    sym: u8,
    count: u8,
    code: u8,
};

test "Creating Huffman Codes" {
    const allo = std.testing.allocator;
    const data = "aaaaaaaaabbbbbbccccddddddffffeegghi";
    // extract freqs
    const freqs = try countFreqs(data);
    // parse bins
    const n_syms: usize = blk: {
        var n_syms: usize = 0;
        for (freqs) |freq| n_syms += @intFromBool(freq > 0);
        break :blk n_syms;
    };
    var bins: std.ArrayList(Bin) = try .initCapacity(allo, n_syms);
    defer bins.deinit(allo);
    for (freqs, 0..) |freq, i| {
        if (freq == 0) continue;
        try bins.append(allo, .{
            .count = freq,
            .sym = @truncate(i),
            .code = 0,
        });
    }
    // sort bins - in gt fashion (want max value at beginning)
    const Context = struct {
        bins: []Bin,
        pub fn lessThanFn(ctx: @This(), a: Bin, b: Bin) bool {
            _ = ctx;
            return a.count > b.count;
        }
    };
    const ctx = Context{ .bins = bins.items };
    std.sort.pdq(Bin, bins.items, ctx, Context.lessThanFn);
    const expected_order = [_]u8{ 'a', 'b', 'd', 'c', 'f', 'e', 'g', 'h', 'i' };
    for (bins.items, expected_order) |bin, eorder|
        try std.testing.expectEqual(eorder, bin.sym);
    // create codes
    var n_counts: usize = 1;
    var curr_count: usize = 0;
    for (1..n_syms - 1) |i| {
        if (curr_count == n_counts)
            n_counts *= 2;
        bins.items[i].code = bins.items[i - 1].code + 2;
        curr_count += 1;
    }
    // std.debug.print("Curr Count: {}\n", .{curr_count});
    // std.debug.print("Num Counts: {}\n", .{n_counts});
    bins.items[n_syms - 1].code = bins.items[n_syms - 2].code + 1;
    const expected_codes =
        [_]u32{ 0b0, 0b10, 0b100, 0b110, 0b1000, 0b1010, 0b1100, 0b1110, 0b1111 };
    for (bins.items, expected_codes) |bin, ecode| {
        // std.debug.print("{c}: {b} - {b}\n", .{ bin.sym, bin.code, ecode });
        try std.testing.expectEqual(ecode, bin.code);
    }
}

const EncodedData = struct {
    // len = pre-computed length of encoded data
    // assumes # of encoded symbols <= 64 bits

    const T: type = u64;
    const bits: u16 = @typeInfo(T).int.bits;

    data: []u64, // data containing encoded message
    pos: u64 = 0, // current position in data
    bits_left: u16 = bits, // 64 // bits left at current position
    total_bits: u64, // total # of bits for encoded msg = pre-computed

    pub fn init(allo: std.mem.Allocator, total_bits: usize) !@This() {
        // total length/bits
        if (total_bits == 0) return error.GivenZeroTotalBits;
        const total_len = std.math.divCeil(T, total_bits, bits) catch unreachable;
        // reset data
        const data = try allo.alloc(T, total_len);
        @memset(data, 0);
        // output
        return .{
            .data = data,
            .total_bits = total_bits,
        };
    }

    pub fn add(self: *@This(), code: T) void {
        // assumes code length <= 64 bits long
        // get # of bits a code consumes
        const consumes_n_bits = blk: {
            var consumes_n_bits: u16 = bits - @clz(code);
            consumes_n_bits += @intFromBool(consumes_n_bits == 0);
            break :blk consumes_n_bits;
        };
        // get data
        var curr_data = self.data[self.pos];
        // if # of bits > bits left, split data over 2 positions
        if (consumes_n_bits > self.bits_left) {
            // shift data
            const shift_right = consumes_n_bits - self.bits_left;
            curr_data |= code >> @truncate(shift_right);
            // assign
            self.data[self.pos] = curr_data;
            // adv
            self.pos += 1;
            // reset
            curr_data = self.data[self.pos];
            self.bits_left = bits;
            // shift data
            const shift_amt = bits - shift_right;
            curr_data |= code << @truncate(shift_amt);
            // assign
            self.data[self.pos] = curr_data;
            self.bits_left = shift_amt;
        } else {
            // shift data
            const shift_left = self.bits_left - consumes_n_bits;
            curr_data |= code << @truncate(shift_left);
            // assign
            self.bits_left = shift_left;
            self.data[self.pos] = curr_data;
        }
    }

    pub fn sub(self: *@This()) u32 {
        // get next code
        // opp of add

    }

    pub fn deinit(self: *@This(), allo: std.mem.Allocator) void {
        allo.free(self.data);
    }

    pub fn print(self: *const @This()) void {
        for (self.data) |datum| std.debug.print("{b} ", .{datum});
        std.debug.print("\n", .{});
    }
};

const Huffman = struct {
    codes: [256]u32, // organized by symbol,
    syms: [256]u8, // organized by code (0 = 1st position, 2:2:n-1 = 1:1:(n-1)/2 codes, n = last code)
    encoded_data: EncodedData,

    pub fn init(allo: std.mem.Allocator, data: []const u8) !@This() {
        // creates codes on init
        // assumes only 256 symbols at max - more = error
        // extract freqs of each symbol
        const freqs = try countFreqs(data);
        // parse # of symbols
        const n_syms: usize = blk: {
            var n_syms: usize = 0;
            for (freqs) |freq| n_syms += @intFromBool(freq > 0);
            break :blk n_syms;
        };
        if (n_syms > 256) return error.MoreThan256SymbolsFound;
        // create bins
        var bins = blk: {
            var bins: [256]Bin = [_]Bin{.{ .code = 0, .count = 0, .sym = 0 }} ** 256;
            var j: usize = 0;
            for (freqs, 0..) |freq, i| {
                if (freq == 0) continue;
                bins[j] = .{
                    .count = freq,
                    .sym = @as(u8, @truncate(i)),
                    .code = 0,
                };
                j += 1;
            }
            break :blk bins;
        };
        // sort bins in gt fashion (want most freq symbol at beginning)
        const Context = struct {
            bins: []Bin,
            pub fn lessThanFn(ctx: @This(), a: Bin, b: Bin) bool {
                _ = ctx;
                return a.count > b.count;
            }
        };
        const ctx = Context{ .bins = &bins };
        std.sort.pdq(Bin, ctx.bins, ctx, Context.lessThanFn);
        // create huffman codes for each symbol
        var n_counts: usize = 1;
        var curr_count: usize = 0;
        for (1..n_syms - 1) |i| {
            if (curr_count == n_counts)
                n_counts *= 2;
            bins[i].code = bins[i - 1].code + 2;
            curr_count += 1;
        }
        bins[n_syms - 1].code = bins[n_syms - 2].code + 1;
        // convert to an array of 255
        // each position = symbol,
        // each value = code
        var codes = [_]u32{0} ** 256;
        for (0..n_syms) |i| codes[bins[i].sym] = bins[i].code;
        // create list of syms
        var syms = [_]u8{0};
        for (0..n_syms) |i| syms[i] = bins[i].sym;
        // compute encoded length
        var encoded_length: usize = 0;
        for (0..n_syms) |i| {
            var n_bits_per_code = @typeInfo(@TypeOf(codes[0])).int.bits - @clz(bins[i].code);
            n_bits_per_code += @intFromBool(n_bits_per_code == 0);
            encoded_length += (n_bits_per_code * bins[i].count);
        }
        // output
        return .{
            .codes = codes,
            .syms = syms,
            .encoded_data = try .init(allo, encoded_length),
        };
    }

    pub fn encode(
        self: *@This(),
        data: []const u8,
    ) !void {
        for (data) |ch|
            self.encoded_data.add(self.codes[ch]);
    }

    pub fn decode(
        self: *const @This(),
        allo: std.mem.Allocator,
        bit_strs: []const u64,
        total_bits: u64,
    ) !void {
        // create mem
        var data = try allo.alloc(u8, total_bits);
        defer allo.free(data);
        // loop bit str
        for (bit_strs) |bit_str| {
            self.encoded_data.sub();
        }
        // return data;
    }

    pub fn deinit(self: *@This(), allo: std.mem.Allocator) void {
        self.encoded_data.deinit(allo);
    }

    pub fn printCodes(self: *const @This()) void {
        for (self.codes, 0..) |code, i|
            if (code > 0)
                std.debug.print("{c}: {b}\n", .{ @as(u8, @truncate(i)), code });
    }

    pub fn printEncodedMsg(self: *const @This()) void {
        self.encoded_data.print();
    }
};

test "Huffman Encoding" {
    const allo = std.testing.allocator;
    const data = [_][]const u8{
        "bacab",
        "aaaaaaaaaabbbbbbbbcccccdddddddfffffeeiggghhi", // a:10,b8,c:5,d:7,f:5,e:2,g:3,h:2,i:2
    };
    const expected_encoded_data = [_][]const u64{
        &.{0b1001101000000000000000000000000000000000000000000000000000000000},
        &.{
            0b0000000000101010101010101011011011011011010010010010010010010010,
            0b00010001000100010001100110011111010101010101110111011110000000000,
        },
    };
    for (data, expected_encoded_data) |datum, expected_encoded_datum| {
        // init/deinit
        var huff: Huffman = try .init(allo, datum);
        defer huff.deinit(allo);
        // code
        huff.printCodes();
        // encode
        try huff.encode(datum);
        huff.printEncodedMsg();
        for (huff.encoded_data.data, expected_encoded_datum, 0..) |ed, eed, i| {
            std.testing.expectEqual(eed, ed) catch |err| {
                std.debug.print("Failed On Loop: {}\n", .{i});
                std.debug.print("{b}\n{b}\n", .{ ed, eed });
                return err;
            };
        }
    }
}

// Learn about amazon:
// kinesis - pick point in time and read forward
//  - apache flink
//  - system design questions
// lambda
// kafka
// cassandra
// mongobleed - mongo db
// what is an mce architecture?

// assignments, props (prefabs), world gen in hytale
// how to create a portal + instanced world + bounded space - create a biome
// andrej karpathy -
