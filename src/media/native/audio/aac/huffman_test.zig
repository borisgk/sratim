const std = @import("std");
const huffman = @import("huffman.zig");

test "Verify Huffman Codebook 11 Trie decoding" {
    // Symbol 0 in CB11 has code 0x000, 4 bits (0000)
    const data = [_]u8{ 0x00, 0x00 };
    var reader = huffman.BitReader.init(&data);
    const sym = try huffman.decodeSymbol(&reader, &huffman.CB11_TRIE);
    try std.testing.expectEqual(@as(u16, 0), sym);
}
