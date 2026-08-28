const std = @import("std");

/// BitReader for reading unaligned MSB-first bits from an AC-3 bitstream.
pub const BitReader = struct {
    bytes: []const u8,
    bit_offset: usize = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes, .bit_offset = 0 };
    }

    pub inline fn readBits(self: *BitReader, comptime T: type, num_bits: usize) !T {
        if (num_bits == 0) return 0;
        if (self.bit_offset + num_bits > self.bytes.len * 8) return error.EndOfBitstream;
        var val: u32 = 0;
        var bits_left = num_bits;
        while (bits_left > 0) {
            const byte_idx = self.bit_offset >> 3;
            const bit_in_byte = @as(u3, @intCast(self.bit_offset & 7));
            const avail_in_byte = @as(usize, 8) - @as(usize, bit_in_byte);
            const take = @min(bits_left, avail_in_byte);
            const shift = avail_in_byte - take;
            const mask = (@as(u32, 1) << @intCast(take)) - 1;
            const bits = (@as(u32, self.bytes[byte_idx]) >> @intCast(shift)) & mask;
            val = (val << @intCast(take)) | bits;
            self.bit_offset += take;
            bits_left -= take;
        }
        return @intCast(val);
    }

    pub inline fn readBit(self: *BitReader) !u1 {
        return self.readBits(u1, 1);
    }

    pub inline fn readSignedBits(self: *BitReader, num_bits: usize) !i32 {
        const u_val = try self.readBits(u32, num_bits);
        const sign_bit = @as(u32, 1) << @intCast(num_bits - 1);
        if ((u_val & sign_bit) != 0) {
            const mask = (@as(u32, 1) << @intCast(num_bits)) - 1;
            return @as(i32, @bitCast(u_val | ~mask));
        } else {
            return @as(i32, @intCast(u_val));
        }
    }
};
