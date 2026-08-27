const std = @import("std");
const dsp = @import("dsp.zig");
const imdct = @import("imdct.zig");

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

pub const SAMPLE_RATES: [3]u32 = .{ 48000, 44100, 32000 };

pub const FRAME_SIZE_TABLE: [38][3]u16 = .{
    .{ 64, 69, 96 },       .{ 64, 70, 96 },       .{ 80, 87, 120 },      .{ 80, 88, 120 },
    .{ 96, 104, 144 },     .{ 96, 105, 144 },     .{ 112, 121, 168 },    .{ 112, 122, 168 },
    .{ 128, 139, 192 },    .{ 128, 140, 192 },    .{ 160, 174, 240 },    .{ 160, 175, 240 },
    .{ 192, 208, 288 },    .{ 192, 209, 288 },    .{ 224, 243, 336 },    .{ 224, 244, 336 },
    .{ 256, 278, 384 },    .{ 256, 279, 384 },    .{ 320, 348, 480 },    .{ 320, 349, 480 },
    .{ 384, 417, 576 },    .{ 384, 418, 576 },    .{ 448, 487, 672 },    .{ 448, 488, 672 },
    .{ 512, 557, 768 },    .{ 512, 558, 768 },    .{ 640, 696, 960 },    .{ 640, 697, 960 },
    .{ 768, 835, 1152 },   .{ 768, 836, 1152 },   .{ 896, 975, 1344 },   .{ 896, 976, 1344 },
    .{ 1024, 1114, 1536 }, .{ 1024, 1115, 1536 }, .{ 1152, 1253, 1728 }, .{ 1152, 1254, 1728 },
    .{ 1280, 1393, 1920 }, .{ 1280, 1394, 1920 },
};

pub const NFCHANS_TBL: [8]usize = .{ 2, 1, 2, 3, 3, 4, 4, 5 };

const EXP_REUSE = 0;
const EXP_D15 = 1;
const EXP_D25 = 2;
const EXP_D45 = 3;

const DELTA_BIT_NONE = 0;
const DELTA_BIT_REUSE = 1;
const DELTA_BIT_NEW = 2;
const DELTA_BIT_RESERVED = 3;

const EXP_1: [128]i8 = .{
    -2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,-2,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
     2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    25,25,25
};
const EXP_2: [128]i8 = .{
    -2,-2,-2,-2,-2,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    -2,-2,-2,-2,-2,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    -2,-2,-2,-2,-2,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    -2,-2,-2,-2,-2,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    -2,-2,-2,-2,-2,-1,-1,-1,-1,-1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2,
    25,25,25
};
const EXP_3: [128]i8 = .{
    -2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,
    -2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,
    -2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,
    -2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,
    -2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,-2,-1, 0, 1, 2,
    25,25,25
};

const DITHER_LUT: [256]u16 = .{
    0x0000, 0xa011, 0xe033, 0x4022, 0x6077, 0xc066, 0x8044, 0x2055,
    0xc0ee, 0x60ff, 0x20dd, 0x80cc, 0xa099, 0x0088, 0x40aa, 0xe0bb,
    0x21cd, 0x81dc, 0xc1fe, 0x61ef, 0x41ba, 0xe1ab, 0xa189, 0x0198,
    0xe123, 0x4132, 0x0110, 0xa101, 0x8154, 0x2145, 0x6167, 0xc176,
    0x439a, 0xe38b, 0xa3a9, 0x03b8, 0x23ed, 0x83fc, 0xc3de, 0x63cf,
    0x8374, 0x2365, 0x6347, 0xc356, 0xe303, 0x4312, 0x0330, 0xa321,
    0x6257, 0xc246, 0x8264, 0x2275, 0x0220, 0xa231, 0xe213, 0x4202,
    0xa2b9, 0x02a8, 0x428a, 0xe29b, 0xc2ce, 0x62df, 0x22fd, 0x82ec,
    0x8734, 0x2725, 0x6707, 0xc716, 0xe743, 0x4752, 0x0770, 0xa761,
    0x47da, 0xe7cb, 0xa7e9, 0x07f8, 0x27ad, 0x87bc, 0xc79e, 0x678f,
    0xa6f9, 0x06e8, 0x46ca, 0xe6db, 0xc68e, 0x669f, 0x26bd, 0x86ac,
    0x6617, 0xc606, 0x8624, 0x2635, 0x0660, 0xa671, 0xe653, 0x4642,
    0xc4ae, 0x64bf, 0x249d, 0x848c, 0xa4d9, 0x04c8, 0x44ea, 0xe4fb,
    0x0440, 0xa451, 0xe473, 0x4462, 0x6437, 0xc426, 0x8404, 0x2415,
    0xe563, 0x4572, 0x0550, 0xa541, 0x8514, 0x2505, 0x6527, 0xc536,
    0x258d, 0x859c, 0xc5be, 0x65af, 0x45fa, 0xe5eb, 0xa5c9, 0x05d8,
    0xae79, 0x0e68, 0x4e4a, 0xee5b, 0xce0e, 0x6e1f, 0x2e3d, 0x8e2c,
    0x6e97, 0xce86, 0x8ea4, 0x2eb5, 0x0ee0, 0xaef1, 0xeed3, 0x4ec2,
    0x8fb4, 0x2fa5, 0x6f87, 0xcf96, 0xefc3, 0x4fd2, 0x0ff0, 0xafe1,
    0x4f5a, 0xef4b, 0xaf69, 0x0f78, 0x2f2d, 0x8f3c, 0xcf1e, 0x6f0f,
    0xede3, 0x4df2, 0x0dd0, 0xadc1, 0x8d94, 0x2d85, 0x6da7, 0xcdb6,
    0x2d0d, 0x8d1c, 0xcd3e, 0x6d2f, 0x4d7a, 0xed6b, 0xad49, 0x0d58,
    0xcc2e, 0x6c3f, 0x2c1d, 0x8c0c, 0xac59, 0x0c48, 0x4c6a, 0xec7b,
    0x0cc0, 0xacd1, 0xecf3, 0x4ce2, 0x6cb7, 0xcca6, 0x8c84, 0x2c95,
    0x294d, 0x895c, 0xc97e, 0x696f, 0x493a, 0xe92b, 0xa909, 0x0918,
    0xe9a3, 0x49b2, 0x0990, 0xa981, 0x89d4, 0x29c5, 0x69e7, 0xc9f6,
    0x0880, 0xa891, 0xe8b3, 0x48a2, 0x68f7, 0xc8e6, 0x88c4, 0x28d5,
    0xc86e, 0x687f, 0x285d, 0x884c, 0xa819, 0x0808, 0x482a, 0xe83b,
    0x6ad7, 0xcac6, 0x8ae4, 0x2af5, 0x0aa0, 0xaab1, 0xea93, 0x4a82,
    0xaa39, 0x0a28, 0x4a0a, 0xea1b, 0xca4e, 0x6a5f, 0x2a7d, 0x8a6c,
    0x4b1a, 0xeb0b, 0xab29, 0x0b38, 0x2b6d, 0x8b7c, 0xcb5e, 0x6b4f,
    0x8bf4, 0x2be5, 0x6bc7, 0xcbd6, 0xeb83, 0x4b92, 0x0bb0, 0xaba1,
};

const HTH_TAB: [3][50]i32 = .{
    .{0x730, 0x730, 0x7c0, 0x800, 0x820, 0x840, 0x850, 0x850, 0x860, 0x860,
      0x860, 0x860, 0x860, 0x870, 0x870, 0x870, 0x880, 0x880, 0x890, 0x890,
      0x8a0, 0x8a0, 0x8b0, 0x8b0, 0x8c0, 0x8c0, 0x8d0, 0x8e0, 0x8f0, 0x900,
      0x910, 0x910, 0x910, 0x910, 0x900, 0x8f0, 0x8c0, 0x870, 0x820, 0x7e0,
      0x7a0, 0x770, 0x760, 0x7a0, 0x7c0, 0x7c0, 0x6e0, 0x400, 0x3c0, 0x3c0},
    .{0x710, 0x710, 0x7a0, 0x7f0, 0x820, 0x830, 0x840, 0x850, 0x850, 0x860,
      0x860, 0x860, 0x860, 0x860, 0x870, 0x870, 0x870, 0x880, 0x880, 0x880,
      0x890, 0x890, 0x8a0, 0x8a0, 0x8b0, 0x8b0, 0x8c0, 0x8c0, 0x8e0, 0x8f0,
      0x900, 0x910, 0x910, 0x910, 0x910, 0x900, 0x8e0, 0x8b0, 0x870, 0x820,
      0x7e0, 0x7b0, 0x760, 0x770, 0x7a0, 0x7c0, 0x780, 0x5d0, 0x3c0, 0x3c0},
    .{0x680, 0x680, 0x750, 0x7b0, 0x7e0, 0x810, 0x820, 0x830, 0x840, 0x850,
      0x850, 0x850, 0x860, 0x860, 0x860, 0x860, 0x860, 0x860, 0x860, 0x860,
      0x870, 0x870, 0x870, 0x870, 0x880, 0x880, 0x880, 0x890, 0x8a0, 0x8b0,
      0x8c0, 0x8d0, 0x8e0, 0x8f0, 0x900, 0x910, 0x910, 0x910, 0x900, 0x8f0,
      0x8d0, 0x8b0, 0x840, 0x7f0, 0x790, 0x760, 0x7a0, 0x7c0, 0x7b0, 0x720},
};

const BND_TAB: [30]usize = .{
    21, 22,  23,  24,  25,  26,  27,  28,  31,  34,
    37, 40,  43,  46,  49,  55,  61,  67,  73,  79,
    85, 97, 109, 121, 133, 157, 181, 205, 229, 253
};

const CPL_BND_TAB: [16]usize = .{
    31, 35, 37, 39, 41, 42, 43, 44,
    45, 45, 46, 46, 47, 47, 48, 48
};

const LA_TAB: [256]i8 = .{
    -64, -63, -62, -61, -60, -59, -58, -57, -56, -55, -54, -53,
    -52, -52, -51, -50, -49, -48, -47, -47, -46, -45, -44, -44,
    -43, -42, -41, -41, -40, -39, -38, -38, -37, -36, -36, -35,
    -35, -34, -33, -33, -32, -32, -31, -30, -30, -29, -29, -28,
    -28, -27, -27, -26, -26, -25, -25, -24, -24, -23, -23, -22,
    -22, -21, -21, -21, -20, -20, -19, -19, -19, -18, -18, -18,
    -17, -17, -17, -16, -16, -16, -15, -15, -15, -14, -14, -14,
    -13, -13, -13, -13, -12, -12, -12, -12, -11, -11, -11, -11,
    -10, -10, -10, -10, -10,  -9,  -9,  -9,  -9,  -9,  -8,  -8,
     -8,  -8,  -8,  -8,  -7,  -7,  -7,  -7,  -7,  -7,  -6,  -6,
     -6,  -6,  -6,  -6,  -6,  -6,  -5,  -5,  -5,  -5,  -5,  -5,
     -5,  -5,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,  -4,
     -4,  -3,  -3,  -3,  -3,  -3,  -3,  -3,  -3,  -3,  -3,  -3,
     -3,  -3,  -3,  -2,  -2,  -2,  -2,  -2,  -2,  -2,  -2,  -2,
     -2,  -2,  -2,  -2,  -2,  -2,  -2,  -2,  -2,  -2,  -1,  -1,
     -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,
     -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,  -1,
     -1,  -1,  -1,  -1,  -1,  -1,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
      0,   0,   0,   0
};

const BAP_TAB: [305]i8 = initBapTab();

fn initBapTab() [305]i8 {
    var tab: [305]i8 = undefined;
    for (0..93) |i| tab[i] = 16;
    const middle: [64]i8 = .{
        16, 16, 16, 16, 16, 16, 16, 16, 16, 14, 14, 14, 14, 14, 14, 14,
        14, 12, 12, 12, 12, 11, 11, 11, 11, 10, 10, 10, 10,  9,  9,  9,
         9,  8,  8,  8,  8,  7,  7,  7,  7,  6,  6,  6,  6,  5,  5,  5,
         5,  4,  4, -3, -3,  3,  3,  3, -2, -2, -1, -1, -1, -1, -1,  0,
    };
    for (middle, 0..) |v, i| tab[93 + i] = v;
    for (0..148) |i| tab[157 + i] = 0;
    return tab;
}

const SCALE_FACTOR: [25]f32 = initScaleFactor();
fn initScaleFactor() [25]f32 {
    var sf: [25]f32 = undefined;
    var v: f64 = 1.0 / 32768.0;
    for (0..25) |i| {
        sf[i] = @floatCast(v);
        v *= 0.5;
    }
    return sf;
}

const LEVEL_3DB: f32 = 0.7071067811865475;

const Q_1_0 = makeQ1(0);
const Q_1_1 = makeQ1(1);
const Q_1_2 = makeQ1(2);

fn makeQ1(comptime comp: usize) [32]f32 {
    var tbl: [32]f32 = @splat(0.0);
    for (0..27) |code| {
        const idx0 = code / 9;
        const idx1 = (code / 3) % 3;
        const idx2 = code % 3;
        const idx = switch (comp) {
            0 => idx0,
            1 => idx1,
            2 => idx2,
            else => unreachable,
        };
        const level: f32 = switch (idx) {
            0 => -2.0 / 3.0,
            1 => 0.0,
            2 => 2.0 / 3.0,
            else => unreachable,
        };
        tbl[code] = level * 32768.0;
    }
    return tbl;
}

const Q_2_0 = makeQ2(0);
const Q_2_1 = makeQ2(1);
const Q_2_2 = makeQ2(2);

fn makeQ2(comptime comp: usize) [128]f32 {
    var tbl: [128]f32 = @splat(0.0);
    for (0..125) |code| {
        const idx0 = code / 25;
        const idx1 = (code / 5) % 5;
        const idx2 = code % 5;
        const idx = switch (comp) {
            0 => idx0,
            1 => idx1,
            2 => idx2,
            else => unreachable,
        };
        const level: f32 = switch (idx) {
            0 => -4.0 / 5.0,
            1 => -2.0 / 5.0,
            2 => 0.0,
            3 => 2.0 / 5.0,
            4 => 4.0 / 5.0,
            else => unreachable,
        };
        tbl[code] = level * 32768.0;
    }
    return tbl;
}

const Q_3: [8]f32 = .{
    (-6.0 / 7.0) * 32768.0, (-4.0 / 7.0) * 32768.0, (-2.0 / 7.0) * 32768.0, 0.0,
    ( 2.0 / 7.0) * 32768.0, ( 4.0 / 7.0) * 32768.0, ( 6.0 / 7.0) * 32768.0, 0.0,
};

const Q_4_0 = makeQ4(0);
const Q_4_1 = makeQ4(1);

fn makeQ4(comptime comp: usize) [128]f32 {
    var tbl: [128]f32 = @splat(0.0);
    for (0..121) |code| {
        const idx0 = code / 11;
        const idx1 = code % 11;
        const idx = if (comp == 0) idx0 else idx1;
        const level: f32 = (-10.0 + 2.0 * @as(f32, @floatFromInt(idx))) / 11.0;
        tbl[code] = level * 32768.0;
    }
    return tbl;
}

const Q_5: [16]f32 = .{
    (-14.0 / 15.0) * 32768.0, (-12.0 / 15.0) * 32768.0, (-10.0 / 15.0) * 32768.0,
    ( -8.0 / 15.0) * 32768.0, ( -6.0 / 15.0) * 32768.0, ( -4.0 / 15.0) * 32768.0,
    ( -2.0 / 15.0) * 32768.0,   0.0                   , (  2.0 / 15.0) * 32768.0,
    (  4.0 / 15.0) * 32768.0, (  6.0 / 15.0) * 32768.0, (  8.0 / 15.0) * 32768.0,
    ( 10.0 / 15.0) * 32768.0, ( 12.0 / 15.0) * 32768.0, ( 14.0 / 15.0) * 32768.0,
    0.0,
};

const SLOW_GAIN: [4]i32 = .{ 0x540, 0x4d8, 0x478, 0x410 };
const DBPB_TAB: [4]i32 = .{ 0xc00, 0x500, 0x300, 0x100 };
const FLOOR_TAB: [8]i32 = .{ 0x910, 0x950, 0x990, 0x9d0, 0xa10, 0xa90, 0xb10, 0x1400 };

const ZERO_DELTBA: [50]i8 = [_]i8{0} ** 50;

pub fn bitAllocate(
    fscod: usize,
    halfrate: usize,
    bai: u32,
    csnroffst: u32,
    channel_bai: u32,
    deltbae: u32,
    deltba: []const i8,
    bndstart: usize,
    start: usize,
    end: usize,
    fastleak_init: i32,
    slowleak_init: i32,
    exp: []const u8,
    bap: []i8,
) void {
    const fdecay = (63 + 20 * @as(i32, @intCast((bai >> 7) & 3))) >> @intCast(halfrate);
    const fgain = 128 + 128 * @as(i32, @intCast(channel_bai & 7));
    const sdecay = (15 + 2 * @as(i32, @intCast(bai >> 9))) >> @intCast(halfrate);
    const sgain = SLOW_GAIN[@intCast((bai >> 5) & 3)];
    const dbknee = DBPB_TAB[@intCast((bai >> 3) & 3)];
    const hth = &HTH_TAB[fscod];
    const deltba_slice: []const i8 = if (deltbae == DELTA_BIT_NONE) &ZERO_DELTBA else deltba;
    var floor_val = FLOOR_TAB[@intCast(bai & 7)];
    const snroffset = 960 - 64 * @as(i32, @intCast(csnroffst)) - 4 * @as(i32, @intCast(channel_bai >> 3)) + floor_val;
    floor_val >>= 5;

    var fastleak = fastleak_init;
    var slowleak = slowleak_init;

    var i = bndstart;
    var j = start;

    if (start == 0) {
        var lowcomp: i32 = 0;
        const j_end = end - 1;

        while (true) {
            if (i < j_end) {
                if (@as(i32, exp[i + 1]) == @as(i32, exp[i]) - 2) {
                    lowcomp = 384;
                } else if (lowcomp != 0 and exp[i + 1] > exp[i]) {
                    lowcomp -= 64;
                }
            }
            const psd = 128 * @as(i32, exp[i]);
            var mask = psd + fgain + lowcomp;
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            mask -= snroffset + 128 * d_val;
            mask = if (mask > 0) 0 else ((-mask) >> 5);
            mask -= floor_val;

            const bap_idx = mask + 4 * @as(i32, exp[i]) + 156;
            bap[i] = if (bap_idx >= 0 and bap_idx < BAP_TAB.len) BAP_TAB[@intCast(bap_idx)] else 0;
            i += 1;
            if (!((i < 3) or ((i < 7) and (exp[i] > exp[i - 1])))) break;
        }

        const psd_last = 128 * @as(i32, exp[i - 1]);
        fastleak = psd_last + fgain;
        slowleak = psd_last + sgain;

        while (i < 7) {
            if (i < j_end) {
                if (@as(i32, exp[i + 1]) == @as(i32, exp[i]) - 2) {
                    lowcomp = 384;
                } else if (lowcomp != 0 and exp[i + 1] > exp[i]) {
                    lowcomp -= 64;
                }
            }
            const psd = 128 * @as(i32, exp[i]);
            fastleak += fdecay;
            if (fastleak > psd + fgain) fastleak = psd + fgain;
            slowleak += sdecay;
            if (slowleak > psd + sgain) slowleak = psd + sgain;

            var mask = if (fastleak + lowcomp < slowleak) fastleak + lowcomp else slowleak;
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            mask -= snroffset + 128 * d_val;
            mask = if (mask > 0) 0 else ((-mask) >> 5);
            mask -= floor_val;

            const bap_idx = mask + 4 * @as(i32, exp[i]) + 156;
            bap[i] = if (bap_idx >= 0 and bap_idx < BAP_TAB.len) BAP_TAB[@intCast(bap_idx)] else 0;
            i += 1;
        }

        if (end == 7) return; // LFE done

        while (i < 20) {
            if (@as(i32, exp[i + 1]) == @as(i32, exp[i]) - 2) {
                lowcomp = 320;
            } else if (lowcomp != 0 and exp[i + 1] > exp[i]) {
                lowcomp -= 64;
            }
            const psd = 128 * @as(i32, exp[i]);
            fastleak += fdecay;
            if (fastleak > psd + fgain) fastleak = psd + fgain;
            slowleak += sdecay;
            if (slowleak > psd + sgain) slowleak = psd + sgain;

            var mask = if (fastleak + lowcomp < slowleak) fastleak + lowcomp else slowleak;
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            mask -= snroffset + 128 * d_val;
            mask = if (mask > 0) 0 else ((-mask) >> 5);
            mask -= floor_val;

            const bap_idx = mask + 4 * @as(i32, exp[i]) + 156;
            bap[i] = if (bap_idx >= 0 and bap_idx < BAP_TAB.len) BAP_TAB[@intCast(bap_idx)] else 0;
            i += 1;
        }

        while (lowcomp > 128) {
            lowcomp -= 128;
            const psd = 128 * @as(i32, exp[i]);
            fastleak += fdecay;
            if (fastleak > psd + fgain) fastleak = psd + fgain;
            slowleak += sdecay;
            if (slowleak > psd + sgain) slowleak = psd + sgain;

            var mask = if (fastleak + lowcomp < slowleak) fastleak + lowcomp else slowleak;
            if (psd > dbknee) mask -= (psd - dbknee) >> 2;
            const hth_idx = i >> @intCast(halfrate);
            if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
            const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
            mask -= snroffset + 128 * d_val;
            mask = if (mask > 0) 0 else ((-mask) >> 5);
            mask -= floor_val;

            const bap_idx = mask + 4 * @as(i32, exp[i]) + 156;
            bap[i] = if (bap_idx >= 0 and bap_idx < BAP_TAB.len) BAP_TAB[@intCast(bap_idx)] else 0;
            i += 1;
        }
        j = i;
    }

    while (j < end) {
        const startband = j;
        const bnd_idx = if (i >= 20) i - 20 else 0;
        const endband = if (bnd_idx < 30 and BND_TAB[bnd_idx] < end) BND_TAB[bnd_idx] else end;
        var psd = 128 * @as(i32, exp[j]);
        j += 1;
        while (j < endband) {
            const next = 128 * @as(i32, exp[j]);
            j += 1;
            const delta = next - psd;
            switch (delta >> 9) {
                -6, -5, -4, -3, -2 => psd = next,
                -1 => {
                    const la_idx: usize = @intCast((-delta) >> 1);
                    if (la_idx < LA_TAB.len) psd = next + LA_TAB[la_idx];
                },
                0 => {
                    const la_idx: usize = @intCast(delta >> 1);
                    if (la_idx < LA_TAB.len) psd += LA_TAB[la_idx];
                },
                else => {},
            }
        }

        fastleak += fdecay;
        if (fastleak > psd + fgain) fastleak = psd + fgain;
        slowleak += sdecay;
        if (slowleak > psd + sgain) slowleak = psd + sgain;

        var mask = if (fastleak < slowleak) fastleak else slowleak;
        if (psd > dbknee) mask -= (psd - dbknee) >> 2;
        const hth_idx = i >> @intCast(halfrate);
        if (hth_idx < 50 and mask > hth[hth_idx]) mask = hth[hth_idx];
        const d_val: i32 = if (i < deltba_slice.len) deltba_slice[i] else 0;
        mask -= snroffset + 128 * d_val;
        mask = if (mask > 0) 0 else ((-mask) >> 5);
        mask -= floor_val;

        i += 1;
        j = startband;
        while (j < endband) : (j += 1) {
            const bap_idx = mask + 4 * @as(i32, exp[j]) + 156;
            bap[j] = if (bap_idx >= 0 and bap_idx < BAP_TAB.len) BAP_TAB[@intCast(bap_idx)] else 0;
        }
    }
}

fn parseExponents(reader: *BitReader, expstr: u2, ngrps: usize, exponent_in: u8, dest: []u8) !u8 {
    var exponent = exponent_in;
    var dest_idx: usize = 0;
    var grp: usize = 0;
    while (grp < ngrps) : (grp += 1) {
        const exps = try reader.readBits(usize, 7);
        if (exps >= 128) return error.InvalidExponentGroup;

        var e = @as(i32, @intCast(exponent)) + EXP_1[exps];
        if (e < 0 or e > 24) return error.ExponentOutOfRange;
        exponent = @intCast(e);
        switch (expstr) {
            EXP_D45 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            EXP_D25 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            EXP_D15 => {
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            else => unreachable,
        }

        e = @as(i32, @intCast(exponent)) + EXP_2[exps];
        if (e < 0 or e > 24) return error.ExponentOutOfRange;
        exponent = @intCast(e);
        switch (expstr) {
            EXP_D45 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            EXP_D25 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            EXP_D15 => {
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            else => unreachable,
        }

        e = @as(i32, @intCast(exponent)) + EXP_3[exps];
        if (e < 0 or e > 24) return error.ExponentOutOfRange;
        exponent = @intCast(e);
        switch (expstr) {
            EXP_D45 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            EXP_D25 => {
                dest[dest_idx] = exponent; dest_idx += 1;
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            EXP_D15 => {
                dest[dest_idx] = exponent; dest_idx += 1;
            },
            else => unreachable,
        }
    }
    return exponent;
}

fn parseDeltba(reader: *BitReader, deltba: []i8) !void {
    @memset(deltba[0..@min(50, deltba.len)], 0);
    const deltnseg = try reader.readBits(usize, 3);
    var j: usize = 0;
    var seg: usize = 0;
    while (seg <= deltnseg) : (seg += 1) {
        j += try reader.readBits(usize, 5);
        const deltlen = try reader.readBits(usize, 4);
        const raw_delta = try reader.readBits(i32, 3);
        const delta: i8 = @intCast(raw_delta - (if (raw_delta >= 4) @as(i32, 3) else @as(i32, 4)));
        for (0..deltlen) |_| {
            if (j < deltba.len) deltba[j] = delta;
            j += 1;
        }
    }
}

const Quantizer = struct {
    q1: [2]f32 = .{ 0.0, 0.0 },
    q2: [2]f32 = .{ 0.0, 0.0 },
    q4: f32 = 0.0,
    q1_ptr: i32 = -1,
    q2_ptr: i32 = -1,
    q4_ptr: i32 = -1,

    pub fn reset(self: *Quantizer) void {
        self.q1_ptr = -1;
        self.q2_ptr = -1;
        self.q4_ptr = -1;
    }
};

inline fn ditherGen(lfsr_state: *u32) f32 {
    const s = lfsr_state.*;
    const nstate: u16 = DITHER_LUT[s >> 8] ^ @as(u16, @truncate(s << 8));
    lfsr_state.* = nstate;
    const signed_val: i16 = @bitCast(nstate);
    return @as(f32, @floatFromInt(signed_val));
}

fn coeffGet(
    reader: *BitReader,
    coeff: []f32,
    exp: []const u8,
    bap: []const i8,
    quantizer: *Quantizer,
    level: f32,
    dither: bool,
    end: usize,
    lfsr_state: *u32,
) !void {
    var factor: [25]f32 = undefined;
    for (0..25) |i| factor[i] = SCALE_FACTOR[i] * level;

    for (0..end) |i| {
        const bapi = bap[i];
        switch (bapi) {
            0 => {
                if (dither) {
                    coeff[i] = ditherGen(lfsr_state) * LEVEL_3DB * factor[exp[i]];
                } else {
                    coeff[i] = 0.0;
                }
            },
            -1 => {
                if (quantizer.q1_ptr >= 0) {
                    coeff[i] = quantizer.q1[@intCast(quantizer.q1_ptr)] * factor[exp[i]];
                    quantizer.q1_ptr -= 1;
                } else {
                    const code = try reader.readBits(usize, 5);
                    quantizer.q1_ptr = 1;
                    quantizer.q1[0] = Q_1_2[code];
                    quantizer.q1[1] = Q_1_1[code];
                    coeff[i] = Q_1_0[code] * factor[exp[i]];
                }
            },
            -2 => {
                if (quantizer.q2_ptr >= 0) {
                    coeff[i] = quantizer.q2[@intCast(quantizer.q2_ptr)] * factor[exp[i]];
                    quantizer.q2_ptr -= 1;
                } else {
                    const code = try reader.readBits(usize, 7);
                    quantizer.q2_ptr = 1;
                    quantizer.q2[0] = Q_2_2[code];
                    quantizer.q2[1] = Q_2_1[code];
                    coeff[i] = Q_2_0[code] * factor[exp[i]];
                }
            },
            3 => {
                const code = try reader.readBits(usize, 3);
                coeff[i] = Q_3[code] * factor[exp[i]];
            },
            -3 => {
                if (quantizer.q4_ptr == 0) {
                    quantizer.q4_ptr = -1;
                    coeff[i] = quantizer.q4 * factor[exp[i]];
                } else {
                    const code = try reader.readBits(usize, 7);
                    quantizer.q4_ptr = 0;
                    quantizer.q4 = Q_4_1[code];
                    coeff[i] = Q_4_0[code] * factor[exp[i]];
                }
            },
            4 => {
                const code = try reader.readBits(usize, 4);
                coeff[i] = Q_5[code] * factor[exp[i]];
            },
            else => {
                if (bapi > 0) {
                    const ubap: usize = @intCast(bapi);
                    const s_val = try reader.readSignedBits(ubap);
                    const shift: u5 = @intCast(16 - ubap);
                    const mant: f32 = @floatFromInt(s_val << shift);
                    coeff[i] = mant * factor[exp[i]];
                } else {
                    coeff[i] = 0.0;
                }
            },
        }
    }
}

fn coeffGetCoupling(
    reader: *BitReader,
    nfchans: usize,
    coeff_scale: []const f32,
    samples: *[6][256]f32,
    quantizer: *Quantizer,
    dithflag: []const bool,
    chincpl: u8,
    cplbndstrc_in: u32,
    cplstrtmant: usize,
    cplendmant: usize,
    cplco_table: *const [5][18]f32,
    cpl_exp: []const u8,
    cpl_bap: []const i8,
    lfsr_state: *u32,
) !void {
    var cplbndstrc = cplbndstrc_in;
    var bnd: usize = 0;
    var i = cplstrtmant;
    var cplco: [5]f32 = undefined;

    while (i < cplendmant) {
        var i_end = i + 12;
        while ((cplbndstrc & 1) != 0) {
            cplbndstrc >>= 1;
            i_end += 12;
        }
        cplbndstrc >>= 1;
        for (0..nfchans) |ch| {
            cplco[ch] = cplco_table[ch][bnd] * coeff_scale[ch];
        }
        bnd += 1;

        while (i < i_end) {
            var cplcoeff: f32 = 0.0;
            const bapi = cpl_bap[i];
            switch (bapi) {
                0 => {
                    const cpl_base = LEVEL_3DB * SCALE_FACTOR[cpl_exp[i]];
                    for (0..nfchans) |ch| {
                        if (((chincpl >> @intCast(ch)) & 1) != 0) {
                            if (dithflag[ch]) {
                                samples[ch][i] = cpl_base * cplco[ch] * ditherGen(lfsr_state);
                            } else {
                                samples[ch][i] = 0.0;
                            }
                        }
                    }
                    i += 1;
                    continue;
                },
                -1 => {
                    if (quantizer.q1_ptr >= 0) {
                        cplcoeff = quantizer.q1[@intCast(quantizer.q1_ptr)];
                        quantizer.q1_ptr -= 1;
                    } else {
                        const code = try reader.readBits(usize, 5);
                        quantizer.q1_ptr = 1;
                        quantizer.q1[0] = Q_1_2[code];
                        quantizer.q1[1] = Q_1_1[code];
                        cplcoeff = Q_1_0[code];
                    }
                },
                -2 => {
                    if (quantizer.q2_ptr >= 0) {
                        cplcoeff = quantizer.q2[@intCast(quantizer.q2_ptr)];
                        quantizer.q2_ptr -= 1;
                    } else {
                        const code = try reader.readBits(usize, 7);
                        quantizer.q2_ptr = 1;
                        quantizer.q2[0] = Q_2_2[code];
                        quantizer.q2[1] = Q_2_1[code];
                        cplcoeff = Q_2_0[code];
                    }
                },
                3 => {
                    const code = try reader.readBits(usize, 3);
                    cplcoeff = Q_3[code];
                },
                -3 => {
                    if (quantizer.q4_ptr == 0) {
                        quantizer.q4_ptr = -1;
                        cplcoeff = quantizer.q4;
                    } else {
                        const code = try reader.readBits(usize, 7);
                        quantizer.q4_ptr = 0;
                        quantizer.q4 = Q_4_1[code];
                        cplcoeff = Q_4_0[code];
                    }
                },
                4 => {
                    const code = try reader.readBits(usize, 4);
                    cplcoeff = Q_5[code];
                },
                else => {
                    if (bapi > 0) {
                        const ubap: usize = @intCast(bapi);
                        const s_val = try reader.readSignedBits(ubap);
                        const shift: u5 = @intCast(16 - ubap);
                        cplcoeff = @floatFromInt(s_val << shift);
                    } else {
                        cplcoeff = 0.0;
                    }
                },
            }

            const cpl_val = cplcoeff * SCALE_FACTOR[cpl_exp[i]];
            for (0..nfchans) |ch| {
                if (((chincpl >> @intCast(ch)) & 1) != 0) {
                    samples[ch][i] = cpl_val * cplco[ch];
                }
            }
            i += 1;
        }
    }
}

pub const Ac3Decoder = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 6,
    acmod: u3 = 7,
    lfeon: u1 = 1,

    delay: [6][256]f32 = [_][256]f32{[_]f32{0.0} ** 256} ** 6,
    lfsr_state: u32 = 1,

    chincpl: u8 = 0,
    cplbegf: usize = 0,
    cplendf: usize = 0,
    cplstrtbnd: usize = 0,
    cplstrtmant: usize = 0,
    cplendmant: usize = 0,
    cplbndstrc: u32 = 0,
    ncplbnd: usize = 0,
    cplco: [5][18]f32 = [_][18]f32{[_]f32{0.0} ** 18} ** 5,

    endmant: [5]usize = [_]usize{0} ** 5,
    cpl_exp: [256]u8 = [_]u8{0} ** 256,
    fbw_exp: [5][256]u8 = [_][256]u8{[_]u8{0} ** 256} ** 5,
    lfe_exp: [256]u8 = [_]u8{0} ** 256,

    bai: u32 = 0,
    csnroffst: u32 = 0,
    cpl_bai: u32 = 0,
    fbw_bai: [5]u32 = [_]u32{0} ** 5,
    lfe_bai: u32 = 0,
    cplfleak: i32 = 0,
    cplsleak: i32 = 0,

    cpl_bap: [256]i8 = [_]i8{0} ** 256,
    fbw_bap: [5][256]i8 = [_][256]i8{[_]i8{0} ** 256} ** 5,
    lfe_bap: [256]i8 = [_]i8{0} ** 256,
    rematflg: u32 = 0,

    pub fn init() Ac3Decoder {
        return .{};
    }

    /// Decodes a single AC-3 audio frame (1536 samples per channel) into stereo interleaved float PCM.
    /// out_stereo_pcm must have capacity for at least 1536 * 2 = 3072 f32 samples.
    /// Returns 1536 (the number of decoded stereo samples).
    pub fn decodeFrame(self: *Ac3Decoder, bytes: []const u8, out_stereo_pcm: []f32) !usize {
        if (bytes.len < 7) return error.InputBufferTooSmall;
        if (out_stereo_pcm.len < 1536 * 2) return error.OutputBufferTooSmall;

        var reader = BitReader.init(bytes);
        const syncword = try reader.readBits(u16, 16);
        if (syncword != 0x0B77) return error.InvalidSyncword;

        _ = try reader.readBits(u16, 16); // crc1
        const fscod = try reader.readBits(u2, 2);
        if (fscod == 3) return error.InvalidSampleRate;
        self.sample_rate = SAMPLE_RATES[fscod];

        const frmsizecod = try reader.readBits(u6, 6);
        if (frmsizecod >= 38) return error.InvalidFrameSizeCode;

        const bsid = try reader.readBits(u5, 5);
        if (bsid > 10) return error.InvalidBitstreamId;

        const bsmod = try reader.readBits(u3, 3);
        _ = bsmod;
        self.acmod = try reader.readBits(u3, 3);

        if ((self.acmod & 1) != 0 and self.acmod != 1) {
            _ = try reader.readBits(u2, 2); // cmixlev
        }
        if ((self.acmod & 4) != 0) {
            _ = try reader.readBits(u2, 2); // surmixlev
        }
        if (self.acmod == 2) {
            _ = try reader.readBits(u2, 2); // dsurmod
        }

        self.lfeon = try reader.readBit();
        const nfchans = NFCHANS_TBL[self.acmod];
        self.channels = @intCast(nfchans + self.lfeon);

        // BSI extra information
        _ = try reader.readBits(u5, 5); // dialnorm
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // compre
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // langcode
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u7, 7); // audprodie
        if (self.acmod == 0) {
            _ = try reader.readBits(u5, 5); // dialnorm2
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // compr2e
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // langcod2e
            if ((try reader.readBit()) == 1) _ = try reader.readBits(u7, 7); // audprodi2e
        }
        _ = try reader.readBits(u2, 2); // copyrightb + origbs
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // timecod1
        if ((try reader.readBit()) == 1) _ = try reader.readBits(u14, 14); // timecod2
        if ((try reader.readBit()) == 1) { // addbsie
            var addbsil = try reader.readBits(u6, 6);
            while (true) {
                _ = try reader.readBits(u8, 8);
                if (addbsil == 0) break;
                addbsil -= 1;
            }
        }

        // Process 6 audio blocks (each produces 256 time-domain samples per channel)
        for (0..6) |blk| {
            var blksw: [5]u1 = undefined;
            for (0..nfchans) |i| blksw[i] = try reader.readBit();
            var dithflag: [5]bool = undefined;
            for (0..nfchans) |i| dithflag[i] = (try reader.readBit()) == 1;

            if ((try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrnge
            if (self.acmod == 0 and (try reader.readBit()) == 1) _ = try reader.readBits(u8, 8); // dynrng2e

            const cplstre = (try reader.readBit()) == 1;
            if (cplstre) {
                const cplinu = (try reader.readBit()) == 1;
                if (cplinu) {
                    self.chincpl = 0;
                    for (0..nfchans) |i| {
                        if ((try reader.readBit()) == 1) self.chincpl |= @as(u8, 1) << @intCast(i);
                    }
                    if (self.acmod == 2) _ = try reader.readBit(); // phsflginu
                    self.cplbegf = try reader.readBits(usize, 4);
                    self.cplendf = try reader.readBits(usize, 4);
                    const ncplsubnd = self.cplendf + 3 - self.cplbegf;
                    self.ncplbnd = ncplsubnd;
                    self.cplstrtbnd = CPL_BND_TAB[self.cplbegf];
                    self.cplstrtmant = self.cplbegf * 12 + 37;
                    self.cplendmant = self.cplendf * 12 + 73;

                    self.cplbndstrc = 0;
                    for (0..ncplsubnd - 1) |i| {
                        if ((try reader.readBit()) == 1) {
                            self.cplbndstrc |= @as(u32, 1) << @intCast(i);
                            self.ncplbnd -= 1;
                        }
                    }
                } else {
                    self.chincpl = 0;
                }
            }

            if (self.chincpl != 0) {
                for (0..nfchans) |i| {
                    if (((self.chincpl >> @intCast(i)) & 1) != 0) {
                        if ((try reader.readBit()) == 1) {
                            const mstrcplco = 3 * (try reader.readBits(usize, 2));
                            for (0..self.ncplbnd) |b| {
                                const cplcoexp = try reader.readBits(usize, 4);
                                var cplcomant = try reader.readBits(usize, 4);
                                if (cplcoexp == 15) {
                                    cplcomant <<= 14;
                                } else {
                                    cplcomant = (cplcomant | 0x10) << 13;
                                }
                                const sf_idx = cplcoexp + mstrcplco;
                                self.cplco[i][b] = @as(f32, @floatFromInt(cplcomant)) * (if (sf_idx < SCALE_FACTOR.len) SCALE_FACTOR[sf_idx] else 0.0);
                            }
                        }
                    }
                }
            }

            if (self.acmod == 2 and (try reader.readBit()) == 1) { // rematstr
                const end: usize = if (self.chincpl != 0) self.cplstrtmant else 253;
                self.rematflg = 0;
                const remat_bands = [4]usize{ 25, 37, 61, 253 };
                var r_idx: usize = 0;
                while (r_idx < 4) : (r_idx += 1) {
                    const r_bit = try reader.readBit();
                    self.rematflg |= @as(u32, r_bit) << @intCast(r_idx);
                    if (remat_bands[r_idx] >= end) break;
                }
            }

            var cplexpstr: u2 = EXP_REUSE;
            if (self.chincpl != 0) cplexpstr = try reader.readBits(u2, 2);
            var chexpstr: [5]u2 = undefined;
            for (0..nfchans) |i| chexpstr[i] = try reader.readBits(u2, 2);
            var lfeexpstr: u1 = 0;
            if (self.lfeon == 1) lfeexpstr = try reader.readBits(u1, 1);

            for (0..nfchans) |i| {
                if (chexpstr[i] != EXP_REUSE) {
                    if (((self.chincpl >> @intCast(i)) & 1) != 0) {
                        self.endmant[i] = self.cplstrtmant;
                    } else {
                        const chbwcod = try reader.readBits(usize, 6);
                        self.endmant[i] = chbwcod * 3 + 73;
                    }
                }
            }

            var do_bit_alloc: u32 = if (blk == 0) 0xFF else 0;

            if (cplexpstr != EXP_REUSE) {
                do_bit_alloc |= 64;
                const shift: u3 = @intCast(cplexpstr - 1);
                const ncplgrps = (self.cplendmant - self.cplstrtmant) / (@as(usize, 3) << shift);
                const cplabsexp = @as(u8, @intCast((try reader.readBits(u8, 4)) << 1));
                _ = try parseExponents(&reader, cplexpstr, ncplgrps, cplabsexp, self.cpl_exp[self.cplstrtmant..]);
            }

            for (0..nfchans) |i| {
                if (chexpstr[i] != EXP_REUSE) {
                    do_bit_alloc |= @as(u32, 1) << @intCast(i);
                    const shift: u3 = @intCast(chexpstr[i] - 1);
                    const grp_size = @as(usize, 3) << shift;
                    const nchgrps = (self.endmant[i] + grp_size - 4) / grp_size;
                    self.fbw_exp[i][0] = try reader.readBits(u8, 4);
                    _ = try parseExponents(&reader, chexpstr[i], nchgrps, self.fbw_exp[i][0], self.fbw_exp[i][1..]);
                    _ = try reader.readBits(u2, 2); // gainrng
                }
            }

            if (lfeexpstr != EXP_REUSE) {
                do_bit_alloc |= 32;
                self.lfe_exp[0] = try reader.readBits(u8, 4);
                _ = try parseExponents(&reader, lfeexpstr, 2, self.lfe_exp[0], self.lfe_exp[1..]);
            }

            if ((try reader.readBit()) == 1) { self.bai = try reader.readBits(u11, 11); do_bit_alloc = 0xFF; }
            if ((try reader.readBit()) == 1) {
                self.csnroffst = try reader.readBits(u6, 6);
                if (self.chincpl != 0) self.cpl_bai = try reader.readBits(u7, 7);
                for (0..nfchans) |i| self.fbw_bai[i] = try reader.readBits(u7, 7);
                if (self.lfeon == 1) self.lfe_bai = try reader.readBits(u7, 7);
                do_bit_alloc = 0xFF;
            }

            if (self.chincpl != 0 and (try reader.readBit()) == 1) {
                self.cplfleak = 9 - (try reader.readBits(i32, 3));
                self.cplsleak = 9 - (try reader.readBits(i32, 3));
                do_bit_alloc |= 64;
            }

            if ((try reader.readBit()) == 1) { // deltbaie
                do_bit_alloc = 0xFF;
                if (self.chincpl != 0) _ = try reader.readBits(u2, 2);
                for (0..nfchans) |i| {
                    const deltbae = try reader.readBits(u2, 2);
                    if (deltbae == DELTA_BIT_NEW) {
                        var dummy_deltba: [50]i8 = undefined;
                        try parseDeltba(&reader, &dummy_deltba);
                    }
                    _ = i;
                }
            }

            if (do_bit_alloc != 0) {
                if (self.chincpl != 0 and (do_bit_alloc & 64) != 0) {
                    bitAllocate(fscod, 0, self.bai, self.csnroffst, self.cpl_bai, DELTA_BIT_NONE, &ZERO_DELTBA, self.cplstrtbnd, self.cplstrtmant, self.cplendmant, self.cplfleak << 8, self.cplsleak << 8, &self.cpl_exp, &self.cpl_bap);
                }
                for (0..nfchans) |i| {
                    if ((do_bit_alloc & (@as(u32, 1) << @intCast(i))) != 0) {
                        bitAllocate(fscod, 0, self.bai, self.csnroffst, self.fbw_bai[i], DELTA_BIT_NONE, &ZERO_DELTBA, 0, 0, self.endmant[i], 0, 0, &self.fbw_exp[i], &self.fbw_bap[i]);
                    }
                }
                if (self.lfeon == 1 and (do_bit_alloc & 32) != 0) {
                    bitAllocate(fscod, 0, self.bai, self.csnroffst, self.lfe_bai, DELTA_BIT_NONE, &ZERO_DELTBA, 0, 0, 7, 0, 0, &self.lfe_exp, &self.lfe_bap);
                }
            }

            if ((try reader.readBit()) == 1) { // skiple
                var skipl = try reader.readBits(usize, 9);
                while (skipl > 0) : (skipl -= 1) _ = try reader.readBits(u8, 8);
            }

            var quantizer = Quantizer{};
            var block_samples: [6][256]f32 = [_][256]f32{[_]f32{0.0} ** 256} ** 6;

            var done_cpl = false;
            for (0..nfchans) |i| {
                try coeffGet(&reader, &block_samples[i], &self.fbw_exp[i], &self.fbw_bap[i], &quantizer, 1.0, dithflag[i], self.endmant[i], &self.lfsr_state);
                if (((self.chincpl >> @intCast(i)) & 1) != 0) {
                    if (!done_cpl) {
                        done_cpl = true;
                        const coeff_scale: [5]f32 = [_]f32{1.0} ** 5;
                        try coeffGetCoupling(&reader, nfchans, &coeff_scale, &block_samples, &quantizer, &dithflag, self.chincpl, self.cplbndstrc, self.cplstrtmant, self.cplendmant, &self.cplco, &self.cpl_exp, &self.cpl_bap, &self.lfsr_state);
                    }
                }
            }

            if (self.lfeon == 1) {
                try coeffGet(&reader, &block_samples[5], &self.lfe_exp, &self.lfe_bap, &quantizer, 1.0, false, 7, &self.lfsr_state);
            }

            // Rematrixing for 2/0 stereo
            if (self.acmod == 2) {
                var j: usize = 0;
                const end_remat = if (self.chincpl != 0) self.cplstrtmant else self.endmant[0];
                const remat_bands = [4]usize{ 25, 37, 61, 253 };
                var b: usize = 0;
                while (j < end_remat and b < 4) : (b += 1) {
                    const endband = @min(remat_bands[b], end_remat);
                    if (((self.rematflg >> @intCast(b)) & 1) != 0) {
                        while (j < endband) : (j += 1) {
                            const left = block_samples[0][j];
                            const right = block_samples[1][j];
                            block_samples[0][j] = left + right;
                            block_samples[1][j] = left - right;
                        }
                    } else {
                        j = endband;
                    }
                }
            }

            // IMDCT transform for each channel
            for (0..nfchans) |i| {
                imdct.imdct512(&block_samples[i], &self.delay[i]);
            }
            if (self.lfeon == 1) {
                imdct.imdct512(&block_samples[5], &self.delay[5]);
            }

            // Downmix block samples to stereo output
            const blk_offset = blk * 256 * 2;
            switch (self.acmod) {
                2 => { // 2.0 Stereo
                    for (0..256) |s| {
                        out_stereo_pcm[blk_offset + s * 2 + 0] = block_samples[0][s];
                        out_stereo_pcm[blk_offset + s * 2 + 1] = block_samples[1][s];
                    }
                },
                1 => { // 1.0 Mono
                    for (0..256) |s| {
                        out_stereo_pcm[blk_offset + s * 2 + 0] = block_samples[0][s];
                        out_stereo_pcm[blk_offset + s * 2 + 1] = block_samples[0][s];
                    }
                },
                7 => { // 3/2 Surround (5.1 with LFE)
                    for (0..256) |s| {
                        const l = block_samples[0][s];
                        const c = block_samples[1][s];
                        const r = block_samples[2][s];
                        const ls = block_samples[3][s];
                        const rs = block_samples[4][s];
                        out_stereo_pcm[blk_offset + s * 2 + 0] = l + c * LEVEL_3DB + ls * LEVEL_3DB;
                        out_stereo_pcm[blk_offset + s * 2 + 1] = r + c * LEVEL_3DB + rs * LEVEL_3DB;
                    }
                },
                else => {
                    // General downmix for other channel configurations
                    for (0..256) |s| {
                        out_stereo_pcm[blk_offset + s * 2 + 0] = block_samples[0][s];
                        out_stereo_pcm[blk_offset + s * 2 + 1] = if (nfchans > 1) block_samples[1][s] else block_samples[0][s];
                    }
                },
            }
        }

        return 1536;
    }
};

test "Ac3Decoder decodes 10 frames from polly_5s.ac3 with high correlation to FFmpeg" {
    const testing = std.testing;
    const file = std.Io.Dir.cwd().openFile(testing.io, "tmp/polly_5s.ac3", .{}) catch return;
    defer file.close(testing.io);

    var buf: [15360]u8 = undefined;
    var reader_file = file.reader(testing.io, &buf);
    _ = try reader_file.interface.readSliceShort(&buf);

    var decoder = Ac3Decoder.init();
    var native_stereo_pcm: [10 * 1536 * 2]f32 = undefined;

    for (0..10) |f| {
        const in_frame = buf[f * 1536 .. (f + 1) * 1536];
        const out_slice = native_stereo_pcm[f * 1536 * 2 .. (f + 1) * 1536 * 2];
        const n_samples = try decoder.decodeFrame(in_frame, out_slice);
        try testing.expectEqual(@as(usize, 1536), n_samples);
    }

    const ref_file = std.Io.Dir.cwd().openFile(testing.io, "tmp/polly_5s_ref.pcm", .{}) catch return;
    defer ref_file.close(testing.io);
    var ref_buf: [122880]u8 align(@alignOf(f32)) = undefined;
    var ref_reader = ref_file.reader(testing.io, &ref_buf);
    _ = try ref_reader.interface.readSliceShort(&ref_buf);
    const ref_floats: []const f32 = @as([*]const f32, @ptrCast(@alignCast(&ref_buf)))[0 .. 122880 / 4];

    var dot: f64 = 0.0;
    var norm_nat: f64 = 0.0;
    var norm_ref: f64 = 0.0;
    for (native_stereo_pcm, ref_floats) |n, r| {
        dot += @as(f64, n) * @as(f64, r);
        norm_nat += @as(f64, n) * @as(f64, n);
        norm_ref += @as(f64, r) * @as(f64, r);
    }
    const corr = dot / (std.math.sqrt(norm_nat) * std.math.sqrt(norm_ref));
    std.debug.print("\nNative Ac3Decoder correlation with FFmpeg: {d:.6}\n", .{corr});
    try testing.expect(corr > 0.95);
}
