id: u8,
h: u8, // horizontal sampling factor
v: u8, // vertical sampling factor
tq: u8, // quant table index
td: u8 = 0, // DC huffman table index (from SOS)
ta: u8 = 0, // AC huffman table index (from SOS)
