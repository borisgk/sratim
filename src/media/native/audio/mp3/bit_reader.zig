const std = @import("std");

/// MSB-first bit reader for parsing MP3 headers, side information, and Huffman bitstreams.
pub const BitReader = struct {
    bytes: []const u8,
    bit_pos: usize = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{
            .bytes = bytes,
            .bit_pos = 0,
        };
    }

    /// Number of remaining unread bits in the buffer.
    pub fn bitsLeft(self: *const BitReader) usize {
        const total_bits = self.bytes.len * 8;
        if (self.bit_pos >= total_bits) return 0;
        return total_bits - self.bit_pos;
    }

    /// Reads 1 single bit (0 or 1).
    pub fn readBit(self: *BitReader) !u1 {
        if (self.bitsLeft() == 0) return error.EndOfBitStream;
        const byte_idx = self.bit_pos >> 3;
        const bit_idx: u3 = @truncate(7 - (self.bit_pos & 7));
        self.bit_pos += 1;
        return @truncate((self.bytes[byte_idx] >> bit_idx) & 1);
    }

    /// Reads up to 32 bits from the bitstream.
    pub fn readBits(self: *BitReader, comptime T: type, count: usize) !T {
        if (count == 0) return 0;
        if (self.bitsLeft() < count) return error.EndOfBitStream;
        var result: u32 = 0;
        for (0..count) |_| {
            const b = try self.readBit();
            result = (result << 1) | b;
        }
        return @intCast(result);
    }

    /// Skips a given number of bits.
    pub fn skipBits(self: *BitReader, count: usize) !void {
        if (self.bitsLeft() < count) return error.EndOfBitStream;
        self.bit_pos += count;
    }

    /// Aligns bit position to the next byte boundary.
    pub fn byteAlign(self: *BitReader) void {
        const rem = self.bit_pos & 7;
        if (rem != 0) {
            self.bit_pos += 8 - rem;
        }
    }
};

test "BitReader basic bit reading" {
    const data = [_]u8{ 0b10110011, 0b11110000 };
    var br = BitReader.init(&data);
    try std.testing.expectEqual(@as(u1, 1), try br.readBit());
    try std.testing.expectEqual(@as(u1, 0), try br.readBit());
    try std.testing.expectEqual(@as(u2, 0b11), try br.readBits(u2, 2));
    try std.testing.expectEqual(@as(u4, 0b0011), try br.readBits(u4, 4));
    try std.testing.expectEqual(@as(u8, 0b11110000), try br.readBits(u8, 8));
    try std.testing.expectEqual(@as(usize, 0), br.bitsLeft());
}
