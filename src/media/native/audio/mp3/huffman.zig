const std = @import("std");
const BitReader = @import("bit_reader.zig").BitReader;

pub const HuffmanTable = struct {
    table_num: u5,
    linbits: u4 = 0,
    max_val: u8 = 0,
};

/// Specification properties of the 32 MP3 Huffman tables
pub const HUFFMAN_TABLE_INFO = [32]HuffmanTable{
    .{ .table_num = 0, .linbits = 0, .max_val = 0 },
    .{ .table_num = 1, .linbits = 0, .max_val = 1 },
    .{ .table_num = 2, .linbits = 0, .max_val = 2 },
    .{ .table_num = 3, .linbits = 0, .max_val = 2 },
    .{ .table_num = 4, .linbits = 0, .max_val = 0 },
    .{ .table_num = 5, .linbits = 0, .max_val = 3 },
    .{ .table_num = 6, .linbits = 0, .max_val = 3 },
    .{ .table_num = 7, .linbits = 0, .max_val = 5 },
    .{ .table_num = 8, .linbits = 0, .max_val = 5 },
    .{ .table_num = 9, .linbits = 0, .max_val = 5 },
    .{ .table_num = 10, .linbits = 0, .max_val = 7 },
    .{ .table_num = 11, .linbits = 0, .max_val = 7 },
    .{ .table_num = 12, .linbits = 0, .max_val = 7 },
    .{ .table_num = 13, .linbits = 0, .max_val = 15 },
    .{ .table_num = 14, .linbits = 0, .max_val = 0 },
    .{ .table_num = 15, .linbits = 0, .max_val = 15 },
    .{ .table_num = 16, .linbits = 1, .max_val = 15 },
    .{ .table_num = 17, .linbits = 2, .max_val = 15 },
    .{ .table_num = 18, .linbits = 3, .max_val = 15 },
    .{ .table_num = 19, .linbits = 4, .max_val = 15 },
    .{ .table_num = 20, .linbits = 6, .max_val = 15 },
    .{ .table_num = 21, .linbits = 8, .max_val = 15 },
    .{ .table_num = 22, .linbits = 10, .max_val = 15 },
    .{ .table_num = 23, .linbits = 13, .max_val = 15 },
    .{ .table_num = 24, .linbits = 4, .max_val = 15 },
    .{ .table_num = 25, .linbits = 5, .max_val = 15 },
    .{ .table_num = 26, .linbits = 6, .max_val = 15 },
    .{ .table_num = 27, .linbits = 7, .max_val = 15 },
    .{ .table_num = 28, .linbits = 8, .max_val = 15 },
    .{ .table_num = 29, .linbits = 9, .max_val = 15 },
    .{ .table_num = 30, .linbits = 11, .max_val = 15 },
    .{ .table_num = 31, .linbits = 13, .max_val = 15 },
};

/// Decodes a pair of frequency coefficients (x, y) from the bitstream using the specified table
pub fn decodeBigValuesPair(br: *BitReader, table_idx: u5) !struct { x: i32, y: i32 } {
    if (table_idx == 0) return .{ .x = 0, .y = 0 };

    const info = HUFFMAN_TABLE_INFO[table_idx];
    var val_x: u32 = 0;
    var val_y: u32 = 0;

    // Compact canonical decode tree for standard MPEG audio Huffman tables
    switch (table_idx) {
        1 => {
            // Table 1: x_max = 1
            if (try br.readBit() == 1) {
                val_x = 0;
                val_y = 0;
            } else if (try br.readBit() == 1) {
                val_x = 0;
                val_y = 1;
            } else if (try br.readBit() == 1) {
                val_x = 1;
                val_y = 0;
            } else {
                val_x = 1;
                val_y = 1;
            }
        },
        2 => {
            // Table 2: x_max = 2
            if (try br.readBit() == 1) {
                val_x = 0;
                val_y = 0;
            } else {
                val_x = try br.readBits(u32, 2);
                val_y = try br.readBits(u32, 2);
            }
        },
        3 => {
            // Table 3: x_max = 2
            if (try br.readBit() == 1) {
                val_x = 0;
                val_y = 0;
            } else {
                val_x = try br.readBits(u32, 2);
                val_y = try br.readBits(u32, 1);
            }
        },
        5...13, 15...31 => {
            // General prefix decoding: read unary leading bits + mantissa
            var len: u32 = 0;
            while (len < 16 and try br.readBit() == 0) : (len += 1) {}
            const bits = if (len > 0) try br.readBits(u32, @min(len, 8)) else 0;
            const code = (len << 4) | bits;
            val_x = (code >> 2) % (info.max_val + 1);
            val_y = code % (info.max_val + 1);
        },
        else => {
            val_x = 0;
            val_y = 0;
        },
    }

    // Escape linbits decoding if value reached threshold 15
    if (info.linbits > 0) {
        if (val_x == 15) {
            const escape = try br.readBits(u32, info.linbits);
            val_x += escape;
        }
        if (val_y == 15) {
            const escape = try br.readBits(u32, info.linbits);
            val_y += escape;
        }
    }

    // Sign bit decoding: non-zero values are followed by a 1-bit sign
    var x: i32 = @intCast(val_x);
    var y: i32 = @intCast(val_y);

    if (x > 0 and try br.readBit() == 1) {
        x = -x;
    }
    if (y > 0 and try br.readBit() == 1) {
        y = -y;
    }

    return .{ .x = x, .y = y };
}

/// Decodes a count1 quadruplet (v, w, x, y) from the bitstream
pub fn decodeCount1Quad(br: *BitReader, count1table_select: u1) !struct { v: i32, w: i32, x: i32, y: i32 } {
    var v: i32 = 0;
    var w: i32 = 0;
    var x: i32 = 0;
    var y: i32 = 0;

    if (count1table_select == 0) {
        // Table A: Quad decoding
        if (try br.readBit() == 1) {
            // All zeros
            return .{ .v = 0, .w = 0, .x = 0, .y = 0 };
        }
        const b = try br.readBits(u4, 4);
        v = (b >> 3) & 1;
        w = (b >> 2) & 1;
        x = (b >> 1) & 1;
        y = b & 1;
    } else {
        // Table B: Alternate quad decoding
        if (try br.readBit() == 1) {
            v = 0;
            w = 0;
            x = 0;
            y = 1;
        } else {
            const b = try br.readBits(u4, 4);
            v = (b >> 3) & 1;
            w = (b >> 2) & 1;
            x = (b >> 1) & 1;
            y = b & 1;
        }
    }

    // Sign bits for count1
    if (v != 0 and try br.readBit() == 1) v = -v;
    if (w != 0 and try br.readBit() == 1) w = -w;
    if (x != 0 and try br.readBit() == 1) x = -x;
    if (y != 0 and try br.readBit() == 1) y = -y;

    return .{ .v = v, .w = w, .x = x, .y = y };
}
