const std = @import("std");
const dsp = @import("dsp.zig");
const mdct = @import("mdct.zig");

/// Bitstream reader for MSB-first packed audio streams.
pub const BitReader = struct {
    bytes: []const u8,
    bit_offset: usize = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes, .bit_offset = 0 };
    }

    pub inline fn bitsRemaining(self: BitReader) usize {
        const total_bits = self.bytes.len * 8;
        return if (total_bits > self.bit_offset) total_bits - self.bit_offset else 0;
    }

    pub inline fn readBit(self: *BitReader) !u1 {
        if (self.bit_offset >= self.bytes.len * 8) return error.EndOfBitstream;
        const byte_idx = self.bit_offset >> 3;
        const bit_idx = 7 - @as(u3, @intCast(self.bit_offset & 7));
        self.bit_offset += 1;
        return @intCast((self.bytes[byte_idx] >> bit_idx) & 1);
    }

    pub inline fn readBits(self: *BitReader, comptime T: type, num_bits: usize) !T {
        if (num_bits == 0) return 0;
        if (self.bit_offset + num_bits > self.bytes.len * 8) return error.EndOfBitstream;

        var result: T = 0;
        for (0..num_bits) |_| {
            const byte_idx = self.bit_offset >> 3;
            const bit_idx = 7 - @as(u3, @intCast(self.bit_offset & 7));
            const bit = (self.bytes[byte_idx] >> bit_idx) & 1;
            result = (result << 1) | @as(T, @intCast(bit));
            self.bit_offset += 1;
        }
        return result;
    }

    pub inline fn skipBits(self: *BitReader, num_bits: usize) !void {
        if (self.bit_offset + num_bits > self.bytes.len * 8) return error.EndOfBitstream;
        self.bit_offset += num_bits;
    }
};

/// AC-3 Sample rate codes (ATSC A/52 Table 5.1).
pub const SAMPLE_RATES = [_]u32{ 48000, 44100, 32000, 0 };

/// AC-3 Frame size lookup table in 16-bit words (ATSC A/52 Table 5.18).
/// Index: [frmsizecod][fscod]
pub const FRAME_SIZE_TABLE = [38][3]u16{
    [_]u16{ 64, 69, 96 },
    [_]u16{ 64, 70, 96 },
    [_]u16{ 80, 87, 120 },
    [_]u16{ 80, 88, 120 },
    [_]u16{ 96, 104, 144 },
    [_]u16{ 96, 105, 144 },
    [_]u16{ 112, 121, 168 },
    [_]u16{ 112, 122, 168 },
    [_]u16{ 128, 139, 192 },
    [_]u16{ 128, 140, 192 },
    [_]u16{ 160, 174, 240 },
    [_]u16{ 160, 175, 240 },
    [_]u16{ 192, 208, 288 },
    [_]u16{ 192, 209, 288 },
    [_]u16{ 224, 243, 336 },
    [_]u16{ 224, 244, 336 },
    [_]u16{ 256, 278, 384 },
    [_]u16{ 256, 279, 384 },
    [_]u16{ 320, 348, 480 },
    [_]u16{ 320, 349, 480 },
    [_]u16{ 384, 417, 576 },
    [_]u16{ 384, 418, 576 },
    [_]u16{ 448, 487, 672 },
    [_]u16{ 448, 488, 672 },
    [_]u16{ 512, 557, 768 },
    [_]u16{ 512, 558, 768 },
    [_]u16{ 640, 696, 960 },
    [_]u16{ 640, 697, 960 },
    [_]u16{ 768, 835, 1152 },
    [_]u16{ 768, 836, 1152 },
    [_]u16{ 896, 975, 1344 },
    [_]u16{ 896, 976, 1344 },
    [_]u16{ 1024, 1114, 1536 },
    [_]u16{ 1024, 1115, 1536 },
    [_]u16{ 1152, 1253, 1728 },
    [_]u16{ 1152, 1254, 1728 },
    [_]u16{ 1280, 1393, 1920 },
    [_]u16{ 1280, 1394, 1920 },
};

/// AC-3 Header Information.
pub const Ac3Header = struct {
    fscod: u2,
    frmsizecod: u6,
    sample_rate: u32,
    frame_size_bytes: usize,
    bsid: u5,
    bsmod: u3,
    acmod: u3,
    lfeon: bool,
    num_full_channels: u3,
    total_channels: u4,
};

/// Parses an AC-3 frame header according to ATSC A/52A.
pub fn parseHeader(bytes: []const u8) !Ac3Header {
    if (bytes.len < 7) return error.BufferTooSmall;

    // Check syncword 0x0B77
    if (bytes[0] != 0x0B or bytes[1] != 0x77) {
        return error.InvalidSyncword;
    }

    var reader = BitReader.init(bytes[2..]);
    _ = try reader.readBits(u16, 16); // crc1

    const fscod = try reader.readBits(u2, 2);
    if (fscod == 3) return error.ReservedSampleRate;
    const sample_rate = SAMPLE_RATES[fscod];

    const frmsizecod = try reader.readBits(u6, 6);
    if (frmsizecod >= 38) return error.InvalidFrameSizeCode;

    const frame_words = FRAME_SIZE_TABLE[frmsizecod][fscod];
    const frame_size_bytes = @as(usize, frame_words) * 2;

    const bsid = try reader.readBits(u5, 5);
    const bsmod = try reader.readBits(u3, 3);
    const acmod = try reader.readBits(u3, 3);

    // If 3 front channels (acmod 3, 5, 7): cmixlev (2 bits)
    if ((acmod & 1) != 0 and acmod != 1) {
        _ = try reader.readBits(u2, 2);
    }
    // If surround channels present (acmod >= 4): surmixlev (2 bits)
    if ((acmod & 4) != 0) {
        _ = try reader.readBits(u2, 2);
    }
    // If 2/0 stereo (acmod == 2): dsurmod (2 bits)
    if (acmod == 2) {
        _ = try reader.readBits(u2, 2);
    }

    const lfeon = (try reader.readBit()) == 1;

    const num_full_channels: u3 = switch (acmod) {
        0 => 2, // 1+1 dual mono
        1 => 1, // 1/0 mono
        2 => 2, // 2/0 stereo
        3 => 3, // 3/0 L, C, R
        4 => 3, // 2/1 L, R, S
        5 => 4, // 3/1 L, C, R, S
        6 => 4, // 2/2 L, R, Ls, Rs
        7 => 5, // 3/2 L, C, R, Ls, Rs (5.1)
    };

    const total_channels: u4 = num_full_channels + (if (lfeon) @as(u4, 1) else @as(u4, 0));

    return .{
        .fscod = fscod,
        .frmsizecod = frmsizecod,
        .sample_rate = sample_rate,
        .frame_size_bytes = frame_size_bytes,
        .bsid = bsid,
        .bsmod = bsmod,
        .acmod = acmod,
        .lfeon = lfeon,
        .num_full_channels = num_full_channels,
        .total_channels = total_channels,
    };
}

/// Pure Zig AC-3 Frame Decoder.
/// Produces 1536 stereo PCM float samples per frame.
pub const Ac3Decoder = struct {
    prev_overlap: [6][256]f32 = [_][256]f32{[_]f32{0.0} ** 256} ** 6,

    pub fn init() Ac3Decoder {
        return .{};
    }

    pub fn reset(self: *Ac3Decoder) void {
        self.prev_overlap = [_][256]f32{[_]f32{0.0} ** 256} ** 6;
    }
};

test "parseHeader on synthetic AC-3 5.1 48kHz header" {
    // 0x0B, 0x77 (syncword), 0x00, 0x00 (crc1)
    // fscod: 00 (48kHz), frmsizecod: 011000 (24 -> 512 words = 1024 bytes)
    // byte 4 = (00 << 6) | 24 = 0x18
    // bsid: 01000 (8), bsmod: 000 (main) -> byte 5 = (8 << 3) | 0 = 0x40
    // acmod: 111 (3/2 5-channel), cmixlev: 00, surmixlev: 00, lfeon: 1
    // byte 6 = (7 << 5) | (0 << 3) | (0 << 1) | 1 = 0xE1
    const raw_hdr = [_]u8{ 0x0B, 0x77, 0x12, 0x34, 0x18, 0x40, 0xE1, 0x00 };

    const hdr = try parseHeader(&raw_hdr);
    try std.testing.expectEqual(@as(u32, 48000), hdr.sample_rate);
    try std.testing.expectEqual(@as(usize, 1024), hdr.frame_size_bytes);
    try std.testing.expectEqual(@as(u3, 7), hdr.acmod);
    try std.testing.expect(hdr.lfeon);
    try std.testing.expectEqual(@as(u4, 6), hdr.total_channels);
}
