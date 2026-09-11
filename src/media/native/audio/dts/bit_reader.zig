const std = @import("std");
const tables = @import("tables.zig");

/// Fast BitReader for reading unaligned MSB-first bits from a DTS bitstream.
pub const BitReader = struct {
    bytes: []const u8,
    bit_offset: usize = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes, .bit_offset = 0 };
    }

    pub inline fn peek64(self: *const BitReader) u64 {
        const byte_idx = self.bit_offset >> 3;
        const bit_in_byte = @as(u6, @intCast(self.bit_offset & 7));
        if (byte_idx + 8 <= self.bytes.len) {
            const w = std.mem.readInt(u64, self.bytes[byte_idx..][0..8], .big);
            return w << bit_in_byte;
        } else {
            var w: u64 = 0;
            var i: usize = byte_idx;
            var count: usize = 0;
            while (i < self.bytes.len and count < 8) : ({
                i += 1;
                count += 1;
            }) {
                w = (w << 8) | self.bytes[i];
            }
            w <<= @intCast((8 - count) * 8);
            return w << bit_in_byte;
        }
    }

    pub inline fn readBits(self: *BitReader, comptime T: type, num_bits: usize) !T {
        if (num_bits == 0) return 0;
        if (self.bit_offset + num_bits > self.bytes.len * 8) return error.EndOfBitstream;
        const v = self.peek64();
        self.bit_offset += num_bits;
        const shift = @as(u6, @intCast(64 - num_bits));
        return @intCast(v >> shift);
    }

    pub inline fn readBit(self: *BitReader) !u1 {
        if (self.bit_offset >= self.bytes.len * 8) return error.EndOfBitstream;
        const v = self.peek64();
        self.bit_offset += 1;
        return @intCast(v >> 63);
    }

    pub inline fn readSignedBits(self: *BitReader, num_bits: usize) !i32 {
        if (num_bits == 0) return 0;
        const u_val = try self.readBits(u32, num_bits);
        const sign_bit = @as(u32, 1) << @intCast(num_bits - 1);
        if ((u_val & sign_bit) != 0) {
            const mask = (@as(u32, 1) << @intCast(num_bits)) - 1;
            return @as(i32, @bitCast(u_val | ~mask));
        } else {
            return @as(i32, @intCast(u_val));
        }
    }

    pub inline fn peekBits(self: *const BitReader, num_bits: usize) !u32 {
        if (num_bits == 0) return 0;
        if (self.bit_offset + num_bits > self.bytes.len * 8) return error.EndOfBitstream;
        const v = self.peek64();
        const shift = @as(u6, @intCast(64 - num_bits));
        return @intCast(v >> shift);
    }

    pub inline fn skipBits(self: *BitReader, count: usize) !void {
        if (self.bit_offset + count > self.bytes.len * 8) return error.EndOfBitstream;
        self.bit_offset += count;
    }

    pub inline fn byteAlign(self: *BitReader) void {
        const rem = self.bit_offset & 7;
        if (rem != 0) {
            self.bit_offset += (8 - rem);
        }
    }

    pub inline fn bitsLeft(self: *const BitReader) usize {
        const total = self.bytes.len * 8;
        return if (total > self.bit_offset) total - self.bit_offset else 0;
    }

    pub inline fn getBytePosition(self: *const BitReader) usize {
        return self.bit_offset >> 3;
    }

    pub inline fn readVlcUnsigned(self: *BitReader, h: *const tables.HuffmanTable) !usize {
        const bits_avail = self.bitsLeft();
        if (bits_avail == 0) return error.EndOfBitstream;
        const v = self.peek64();
        for (0..h.size) |i| {
            const len = h.lens[i];
            if (len <= bits_avail) {
                const shift = @as(u6, @intCast(64 - len));
                if ((v >> shift) == h.codes[i]) {
                    self.bit_offset += len;
                    return i;
                }
            }
        }
        return error.InvalidVlcCode;
    }

    pub inline fn readVlcSigned(self: *BitReader, h: *const tables.HuffmanTable) !i32 {
        const idx = try self.readVlcUnsigned(h);
        const u: u32 = @intCast(idx);
        const res = ((u >> 1) ^ ((u & 1) -% 1)) +% 1;
        return @as(i32, @bitCast(res));
    }
};
