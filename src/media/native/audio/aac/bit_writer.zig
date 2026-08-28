const std = @import("std");

/// Bitstream writer for MSB-first packed AAC frames.
pub const BitWriter = struct {
    buf: []u8,
    bit_offset: usize = 0,

    pub fn init(buf: []u8) BitWriter {
        @memset(buf, 0);
        return .{ .buf = buf, .bit_offset = 0 };
    }

    pub inline fn writeBits(self: *BitWriter, value: u32, count: usize) !void {
        if (count == 0) return;
        if (self.bit_offset + count > self.buf.len * 8) return error.BufferOverflow;

        for (0..count) |i| {
            const shift: u5 = @intCast(count - 1 - i);
            const bit: u1 = @intCast((value >> shift) & 1);
            const byte_idx = self.bit_offset >> 3;
            const bit_idx = 7 - @as(u3, @intCast(self.bit_offset & 7));
            self.buf[byte_idx] |= (@as(u8, bit) << bit_idx);
            self.bit_offset += 1;
        }
    }

    pub inline fn writeBit(self: *BitWriter, bit: u1) !void {
        try self.writeBits(bit, 1);
    }

    pub inline fn byteAlign(self: *BitWriter) !void {
        const rem = self.bit_offset & 7;
        if (rem != 0) {
            try self.writeBits(0, 8 - rem);
        }
    }

    pub inline fn byteCount(self: BitWriter) usize {
        return (self.bit_offset + 7) >> 3;
    }
};
