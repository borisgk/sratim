const std = @import("std");
const mdct = @import("mdct.zig");

/// MPEG-4 Audio Sample Rate Indices (Table 1.16).
pub const FREQ_INDICES = [_]u32{
    96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
};

/// 49 Scale Factor Band offsets for 48kHz (MPEG-4 Audio Part 3, Table 4.110).
pub const SWB_OFFSET_48000 = [_]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,  40,  48,  56,  64,
    72,  80,  88,  96,  108, 120, 132, 144, 160, 176, 196, 216, 240, 264,
    292, 320, 352, 384, 416, 448, 480, 512, 544, 576, 608, 640, 672, 704,
    736, 768, 800, 832, 864, 896, 928, 1024,
};
pub const NUM_SFBS = 49;

/// Precomputed 2048-point Sine window: w[n] = sin(pi / 2048 * (n + 0.5)).
pub const SINE_WINDOW_2048 = blk: {
    @setEvalBranchQuota(5000);
    var w: [2048]f32 = undefined;
    for (0..2048) |i| {
        const angle: f64 = std.math.pi * (@as(f64, @floatFromInt(i)) + 0.5) / 2048.0;
        w[i] = @floatCast(@sin(angle));
    }
    break :blk w;
};

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

/// Pure Zig AAC-LC stereo audio encoder.
/// Converts 1024-sample stereo 48kHz float PCM into raw AAC frames (ISO/IEC 14496-3).
pub const AacEncoder = struct {
    prev_samples_l: [1024]f32 = [_]f32{0.0} ** 1024,
    prev_samples_r: [1024]f32 = [_]f32{0.0} ** 1024,
    sample_rate: u32 = 48000,
    bitrate: u32 = 192000,

    pub fn init(sample_rate: u32, bitrate: u32) AacEncoder {
        return .{
            .sample_rate = sample_rate,
            .bitrate = bitrate,
            .prev_samples_l = [_]f32{0.0} ** 1024,
            .prev_samples_r = [_]f32{0.0} ** 1024,
        };
    }

    pub fn reset(self: *AacEncoder) void {
        self.prev_samples_l = [_]f32{0.0} ** 1024;
        self.prev_samples_r = [_]f32{0.0} ** 1024;
    }

    /// Encodes a 1024-sample stereo frame into raw AAC frame bytes.
    /// out_buf should be at least 1536 bytes.
    /// Returns the number of bytes written.
    pub fn encodeFrame(
        self: *AacEncoder,
        in_l: []const f32,
        in_r: []const f32,
        out_buf: []u8,
    ) !usize {
        std.debug.assert(in_l.len >= 1024);
        std.debug.assert(in_r.len >= 1024);

        // 1. Prepare 2048-point windowed time samples
        var windowed_l: [2048]f32 = undefined;
        var windowed_r: [2048]f32 = undefined;

        for (0..1024) |i| {
            windowed_l[i] = self.prev_samples_l[i] * SINE_WINDOW_2048[i];
            windowed_r[i] = self.prev_samples_r[i] * SINE_WINDOW_2048[i];

            windowed_l[1024 + i] = in_l[i] * SINE_WINDOW_2048[1024 + i];
            windowed_r[1024 + i] = in_r[i] * SINE_WINDOW_2048[1024 + i];
        }

        // Save current samples for next frame's overlap
        @memcpy(&self.prev_samples_l, in_l[0..1024]);
        @memcpy(&self.prev_samples_r, in_r[0..1024]);

        // 2. MDCT Transform: 2048 windowed samples -> 1024 spectral bins
        var spec_l: [1024]f32 = undefined;
        var spec_r: [1024]f32 = undefined;
        mdct.MdctEngine.mdct(1024, &windowed_l, &spec_l);
        mdct.MdctEngine.mdct(1024, &windowed_r, &spec_r);

        // 3. Scale factor calculation & Quantization across 49 bands
        var quant_l: [1024]i16 = undefined;
        var quant_r: [1024]i16 = undefined;
        var sf_l: [NUM_SFBS]u8 = undefined;
        var sf_r: [NUM_SFBS]u8 = undefined;

        quantizeChannel(&spec_l, &sf_l, &quant_l);
        quantizeChannel(&spec_r, &sf_r, &quant_r);

        // 4. Assemble standard AAC raw data block (Channel Pair Element)
        var writer = BitWriter.init(out_buf);

        // ID_CPE (1)
        try writer.writeBits(1, 3);
        // element_instance_tag
        try writer.writeBits(0, 4);
        // common_window = 1
        try writer.writeBit(1);

        // ics_info:
        // ics_reserved_bit = 0
        try writer.writeBit(0);
        // window_sequence = 0 (ONLY_LONG_SEQUENCE)
        try writer.writeBits(0, 2);
        // window_shape = 0 (sine)
        try writer.writeBit(0);
        // max_sfb = 49
        try writer.writeBits(NUM_SFBS, 6);
        // predictor_data_present = 0
        try writer.writeBit(0);

        // ms_mask_present = 0 (independent L/R)
        try writer.writeBits(0, 2);

        // Write Channel 0 (Left)
        try writeIndividualChannelStream(&writer, sf_l[0], sf_l[0..NUM_SFBS], &quant_l);
        // Write Channel 1 (Right)
        try writeIndividualChannelStream(&writer, sf_r[0], sf_r[0..NUM_SFBS], &quant_r);

        // ID_END (7)
        try writer.writeBits(7, 3);
        try writer.byteAlign();

        return writer.byteCount();
    }

    /// Formats a raw AAC frame into a 7-byte standard ADTS frame.
    pub fn buildAdtsHeader(frame_length: usize, sample_rate: u32, channel_count: u3) [7]u8 {
        var sample_idx: u4 = 3; // default 48000 Hz
        for (FREQ_INDICES, 0..) |freq, idx| {
            if (freq == sample_rate) {
                sample_idx = @intCast(idx);
                break;
            }
        }

        const total_len: u13 = @intCast(frame_length + 7);
        var hdr: [7]u8 = undefined;
        hdr[0] = 0xFF;
        hdr[1] = 0xF1; // MPEG-4, Layer 0, Protection Absent (1)
        hdr[2] = (1 << 6) | (@as(u8, sample_idx) << 2) | (@as(u8, channel_count) >> 2);
        hdr[3] = ((@as(u8, channel_count) & 3) << 6) | @as(u8, @intCast((total_len >> 11) & 3));
        hdr[4] = @intCast((total_len >> 3) & 0xFF);
        hdr[5] = @as(u8, @intCast((total_len & 7) << 5)) | 0x1F;
        hdr[6] = 0xFC;
        return hdr;
    }
};

fn quantizeChannel(spec: []const f32, sf: []u8, quant: []i16) void {
    for (0..NUM_SFBS) |b| {
        const start = SWB_OFFSET_48000[b];
        const end = SWB_OFFSET_48000[b + 1];

        var max_val: f32 = 0.0;
        for (start..end) |k| {
            const val = @abs(spec[k]);
            if (val > max_val) max_val = val;
        }

        const calculated_sf: u8 = if (max_val > 1e-6)
            @intCast(std.math.clamp(@as(i32, @intFromFloat(100.0 + 16.0 / 3.0 * std.math.log2(max_val * 4.0 + 1.0))), 0, 255))
        else
            100;
        sf[b] = calculated_sf;

        const factor = @as(f32, @floatCast(std.math.pow(f64, 2.0, -0.1875 * (@as(f64, @floatFromInt(calculated_sf)) - 100.0))));

        for (start..end) |k| {
            const s = spec[k];
            const scaled = @abs(s) * factor;
            const q = std.math.clamp(@as(i32, @intFromFloat(std.math.pow(f32, scaled, 0.75) + 0.4054)), 0, 8191);
            quant[k] = if (s < 0.0) @intCast(-q) else @intCast(q);
        }
    }
}

fn writeIndividualChannelStream(
    writer: *BitWriter,
    global_gain: u8,
    sfs: []const u8,
    quant: []const i16,
) !void {
    // global_gain
    try writer.writeBits(global_gain, 8);

    // Section data:
    // All 49 scalefactor bands use Codebook 11 (Esc codebook).
    // In AAC long windows, section length is written in 5-bit increments:
    // A value of 31 is an escape meaning "add 31 and read another 5 bits".
    try writer.writeBits(11, 4); // Codebook 11
    try writer.writeBits(31, 5); // 31 (continuation escape)
    try writer.writeBits(NUM_SFBS - 31, 5); // 18 (total section length = 49)

    // Scale factor data (differential encoding, codebook 12)
    var prev_sf = global_gain;
    for (sfs) |sf| {
        const diff = @as(i32, sf) - @as(i32, prev_sf);
        prev_sf = sf;
        try writeScaleFactorDiff(writer, diff);
    }

    // Pulse data present = 0, TNS present = 0, Gain control present = 0
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);

    // Spectral data: write pairs using Codebook 11
    var i: usize = 0;
    while (i < 1024) : (i += 2) {
        const x = quant[i];
        const y = quant[i + 1];
        try writeCodebook11Pair(writer, x, y);
    }
}

fn writeScaleFactorDiff(writer: *BitWriter, diff: i32) !void {
    const clamped = std.math.clamp(diff, -60, 60);
    const idx: usize = @intCast(clamped + 60);
    try writer.writeBits(SCALEFACTOR_CODES[idx], SCALEFACTOR_BITS[idx]);
}

fn writeCodebook11Pair(writer: *BitWriter, x: i16, y: i16) !void {
    const ax: u32 = @intCast(@abs(x));
    const ay: u32 = @intCast(@abs(y));

    const qx: u32 = @min(ax, 16);
    const qy: u32 = @min(ay, 16);

    const idx: usize = @intCast(qx * 17 + qy);
    try writer.writeBits(CB11_CODES[idx], CB11_BITS[idx]);

    // Sign bits for non-zero values
    if (qx != 0) {
        try writer.writeBit(if (x < 0) 1 else 0);
    }
    if (qy != 0) {
        try writer.writeBit(if (y < 0) 1 else 0);
    }

    // Escape sequences for values >= 16 (ISO/IEC 14496-3 Section 4.5.3.3.4)
    if (qx == 16) {
        try writeEsc(writer, ax);
    }
    if (qy == 16) {
        try writeEsc(writer, ay);
    }
}

fn writeEsc(writer: *BitWriter, val: u32) !void {
    const coef = @min(val, (1 << 13) - 1);
    const len: usize = 31 - @as(usize, @clz(coef)); // floor(log2(coef)), where coef >= 16 so len >= 4
    const esc_len = len - 4 + 1;
    const esc_prefix: u32 = (@as(u32, 1) << @intCast(esc_len)) - 2;
    try writer.writeBits(esc_prefix, esc_len);
    try writer.writeBits(coef & ((@as(u32, 1) << @intCast(len)) - 1), len);
}

// ISO/IEC 14496-3 Table 4.128: Scalefactor Huffman Codebook
const SCALEFACTOR_CODES = [_]u32{
    0x3ffe8, 0x3ffe6, 0x3ffe7, 0x3ffe5, 0x7fff5, 0x7fff1, 0x7ffed, 0x7fff6,
    0x7ffee, 0x7ffef, 0x7fff0, 0x7fffc, 0x7fffd, 0x7ffff, 0x7fffe, 0x7fff7,
    0x7fff8, 0x7fffb, 0x7fff9, 0x3ffe4, 0x7fffa, 0x3ffe3, 0x1ffef, 0x1fff0,
    0x0fff5, 0x1ffee, 0x0fff2, 0x0fff3, 0x0fff4, 0x0fff1, 0x07ff6, 0x07ff7,
    0x03ff9, 0x03ff5, 0x03ff7, 0x03ff3, 0x03ff6, 0x03ff2, 0x01ff7, 0x01ff5,
    0x00ff9, 0x00ff7, 0x00ff6, 0x007f9, 0x00ff4, 0x007f8, 0x003f9, 0x003f7,
    0x003f5, 0x001f8, 0x001f7, 0x000fa, 0x000f8, 0x000f6, 0x00079, 0x0003a,
    0x00038, 0x0001a, 0x0000b, 0x00004, 0x00000, 0x0000a, 0x0000c, 0x0001b,
    0x00039, 0x0003b, 0x00078, 0x0007a, 0x000f7, 0x000f9, 0x001f6, 0x001f9,
    0x003f4, 0x003f6, 0x003f8, 0x007f5, 0x007f4, 0x007f6, 0x007f7, 0x00ff5,
    0x00ff8, 0x01ff4, 0x01ff6, 0x01ff8, 0x03ff8, 0x03ff4, 0x0fff0, 0x07ff4,
    0x0fff6, 0x07ff5, 0x3ffe2, 0x7ffd9, 0x7ffda, 0x7ffdb, 0x7ffdc, 0x7ffdd,
    0x7ffde, 0x7ffd8, 0x7ffd2, 0x7ffd3, 0x7ffd4, 0x7ffd5, 0x7ffd6, 0x7fff2,
    0x7ffdf, 0x7ffe7, 0x7ffe8, 0x7ffe9, 0x7ffea, 0x7ffeb, 0x7ffe6, 0x7ffe0,
    0x7ffe1, 0x7ffe2, 0x7ffe3, 0x7ffe4, 0x7ffe5, 0x7ffd7, 0x7ffec, 0x7fff4,
    0x7fff3,
};

const SCALEFACTOR_BITS = [_]u5{
    18, 18, 18, 18, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 18, 19, 18, 17, 17, 16, 17, 16, 16, 16, 16, 15, 15,
    14, 14, 14, 14, 14, 14, 13, 13, 12, 12, 12, 11, 12, 11, 10, 10,
    10,  9,  9,  8,  8,  8,  7,  6,  6,  5,  4,  3,  1,  4,  4,  5,
     6,  6,  7,  7,  8,  8,  9,  9, 10, 10, 10, 11, 11, 11, 11, 12,
    12, 13, 13, 13, 14, 14, 16, 15, 16, 15, 18, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19, 19,
    19, 19, 19, 19, 19, 19, 19, 19, 19,
};

// ISO/IEC 14496-3 Table 4.127: Spectral Codebook 11 (289 pairs for values 0..16)
const CB11_CODES = [_]u16{
    0x000, 0x006, 0x019, 0x03d, 0x09c, 0x0c6, 0x1a7, 0x390,
    0x3c2, 0x3df, 0x7e6, 0x7f3, 0xffb, 0x7ec, 0xffa, 0xffe,
    0x38e, 0x005, 0x001, 0x008, 0x014, 0x037, 0x042, 0x092,
    0x0af, 0x191, 0x1a5, 0x1b5, 0x39e, 0x3c0, 0x3a2, 0x3cd,
    0x7d6, 0x0ae, 0x017, 0x007, 0x009, 0x018, 0x039, 0x040,
    0x08e, 0x0a3, 0x0b8, 0x199, 0x1ac, 0x1c1, 0x3b1, 0x396,
    0x3be, 0x3ca, 0x09d, 0x03c, 0x015, 0x016, 0x01a, 0x03b,
    0x044, 0x091, 0x0a5, 0x0be, 0x196, 0x1ae, 0x1b9, 0x3a1,
    0x391, 0x3a5, 0x3d5, 0x094, 0x09a, 0x036, 0x038, 0x03a,
    0x041, 0x08c, 0x09b, 0x0b0, 0x0c3, 0x19e, 0x1ab, 0x1bc,
    0x39f, 0x38f, 0x3a9, 0x3cf, 0x093, 0x0bf, 0x03e, 0x03f,
    0x043, 0x045, 0x09e, 0x0a7, 0x0b9, 0x194, 0x1a2, 0x1ba,
    0x1c3, 0x3a6, 0x3a7, 0x3bb, 0x3d4, 0x09f, 0x1a0, 0x08f,
    0x08d, 0x090, 0x098, 0x0a6, 0x0b6, 0x0c4, 0x19f, 0x1af,
    0x1bf, 0x399, 0x3bf, 0x3b4, 0x3c9, 0x3e7, 0x0a8, 0x1b6,
    0x0ab, 0x0a4, 0x0aa, 0x0b2, 0x0c2, 0x0c5, 0x198, 0x1a4,
    0x1b8, 0x38c, 0x3a4, 0x3c4, 0x3c6, 0x3dd, 0x3e8, 0x0ad,
    0x3af, 0x192, 0x0bd, 0x0bc, 0x18e, 0x197, 0x19a, 0x1a3,
    0x1b1, 0x38d, 0x398, 0x3b7, 0x3d3, 0x3d1, 0x3db, 0x7dd,
    0x0b4, 0x3de, 0x1a9, 0x19b, 0x19c, 0x1a1, 0x1aa, 0x1ad,
    0x1b3, 0x38b, 0x3b2, 0x3b8, 0x3ce, 0x3e1, 0x3e0, 0x7d2,
    0x7e5, 0x0b7, 0x7e3, 0x1bb, 0x1a8, 0x1a6, 0x1b0, 0x1b2,
    0x1b7, 0x39b, 0x39a, 0x3ba, 0x3b5, 0x3d6, 0x7d7, 0x3e4,
    0x7d8, 0x7ea, 0x0ba, 0x7e8, 0x3a0, 0x1bd, 0x1b4, 0x38a,
    0x1c4, 0x392, 0x3aa, 0x3b0, 0x3bc, 0x3d7, 0x7d4, 0x7dc,
    0x7db, 0x7d5, 0x7f0, 0x0c1, 0x7fb, 0x3c8, 0x3a3, 0x395,
    0x39d, 0x3ac, 0x3ae, 0x3c5, 0x3d8, 0x3e2, 0x3e6, 0x7e4,
    0x7e7, 0x7e0, 0x7e9, 0x7f7, 0x190, 0x7f2, 0x393, 0x1be,
    0x1c0, 0x394, 0x397, 0x3ad, 0x3c3, 0x3c1, 0x3d2, 0x7da,
    0x7d9, 0x7df, 0x7eb, 0x7f4, 0x7fa, 0x195, 0x7f8, 0x3bd,
    0x39c, 0x3ab, 0x3a8, 0x3b3, 0x3b9, 0x3d0, 0x3e3, 0x3e5,
    0x7e2, 0x7de, 0x7ed, 0x7f1, 0x7f9, 0x7fc, 0x193, 0xffd,
    0x3dc, 0x3b6, 0x3c7, 0x3cc, 0x3cb, 0x3d9, 0x3da, 0x7d3,
    0x7e1, 0x7ee, 0x7ef, 0x7f5, 0x7f6, 0xffc, 0xfff, 0x19d,
    0x1c2, 0x0b5, 0x0a1, 0x096, 0x097, 0x095, 0x099, 0x0a0,
    0x0a2, 0x0ac, 0x0a9, 0x0b1, 0x0b3, 0x0bb, 0x0c0, 0x18f,
    0x004,
};

const CB11_BITS = [_]u5{
     4,  5,  6,  7,  8,  8,  9, 10, 10, 10, 11, 11, 12, 11, 12, 12,
    10,  5,  4,  5,  6,  7,  7,  8,  8,  9,  9,  9, 10, 10, 10, 10,
    11,  8,  6,  5,  5,  6,  7,  7,  8,  8,  8,  9,  9,  9, 10, 10,
    10, 10,  8,  7,  6,  6,  6,  7,  7,  8,  8,  8,  9,  9,  9, 10,
    10, 10, 10,  8,  8,  7,  7,  7,  7,  8,  8,  8,  8,  9,  9,  9,
    10, 10, 10, 10,  8,  8,  7,  7,  7,  7,  8,  8,  8,  9,  9,  9,
     9, 10, 10, 10, 10,  8,  9,  8,  8,  8,  8,  8,  8,  8,  9,  9,
     9, 10, 10, 10, 10, 10,  8,  9,  8,  8,  8,  8,  8,  8,  9,  9,
     9, 10, 10, 10, 10, 10, 10,  8, 10,  9,  8,  8,  9,  9,  9,  9,
     9, 10, 10, 10, 10, 10, 10, 11,  8, 10,  9,  9,  9,  9,  9,  9,
     9, 10, 10, 10, 10, 10, 10, 11, 11,  8, 11,  9,  9,  9,  9,  9,
     9, 10, 10, 10, 10, 10, 11, 10, 11, 11,  8, 11, 10,  9,  9, 10,
     9, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11,  8, 11, 10, 10, 10,
    10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11,  9, 11, 10,  9,
     9, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11,  9, 11, 10,
    10, 10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11,  9, 12,
    10, 10, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 12, 12,  9,
     9,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  8,  9,
     5,
};

test "AacEncoder encodes stereo sine wave into valid AAC frame" {
    var enc = AacEncoder.init(48000, 192000);

    var in_l: [1024]f32 = undefined;
    var in_r: [1024]f32 = undefined;

    // Generate 1000 Hz stereo test tone
    for (0..1024) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        in_l[i] = 0.5 * @sin(2.0 * std.math.pi * 1000.0 * t);
        in_r[i] = 0.5 * @cos(2.0 * std.math.pi * 1000.0 * t);
    }

    var out_buf: [2048]u8 = undefined;
    const len = try enc.encodeFrame(&in_l, &in_r, &out_buf);

    try std.testing.expect(len > 10 and len < 1536);
    // Verify first 3 bits are ID_CPE (1)
    const first_byte = out_buf[0];
    const element_id = (first_byte >> 5) & 7;
    try std.testing.expectEqual(@as(u8, 1), element_id);
}

test "AacEncoder buildAdtsHeader format" {
    const hdr = AacEncoder.buildAdtsHeader(250, 48000, 2);
    try std.testing.expectEqual(@as(u8, 0xFF), hdr[0]);
    try std.testing.expectEqual(@as(u8, 0xF1), hdr[1]);
    try std.testing.expectEqual(@as(u8, 0x4C), hdr[2]);
}

test "AacEncoder frame is decodable by libavcodec AAC decoder" {
    const c = @import("../../transcoder.zig").c;
    var enc = AacEncoder.init(48000, 192000);

    var in_l: [1024]f32 = undefined;
    var in_r: [1024]f32 = undefined;
    for (0..1024) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        in_l[i] = 0.5 * @sin(2.0 * std.math.pi * 1000.0 * t);
        in_r[i] = 0.5 * @cos(2.0 * std.math.pi * 1000.0 * t);
    }

    var raw_buf: [2048]u8 = undefined;
    const raw_len = try enc.encodeFrame(&in_l, &in_r, &raw_buf);

    // Prefix with ADTS header
    const adts_hdr = AacEncoder.buildAdtsHeader(raw_len, 48000, 2);
    var packet_buf: [2048]u8 = undefined;
    @memcpy(packet_buf[0..7], &adts_hdr);
    @memcpy(packet_buf[7 .. 7 + raw_len], raw_buf[0..raw_len]);
    const total_len = raw_len + 7;

    const dec = c.avcodec_find_decoder(c.AV_CODEC_ID_AAC) orelse return error.DecoderNotFound;
    var dec_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&dec_ctx);

    dec_ctx.*.sample_rate = 48000;
    c.av_channel_layout_default(&dec_ctx.*.ch_layout, 2);

    if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.DecoderOpenFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    pkt.*.data = @ptrCast(&packet_buf);
    pkt.*.size = @intCast(total_len);

    const send_ret = c.avcodec_send_packet(dec_ctx, pkt);
    if (send_ret < 0) {
        var err_buf: [128]u8 = undefined;
        _ = c.av_strerror(send_ret, &err_buf, err_buf.len);
        std.debug.print("avcodec_send_packet failed: {s}\n", .{err_buf});
        return error.SendPacketFailed;
    }

    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(@ptrCast(&frame));

    const rec_ret = c.avcodec_receive_frame(dec_ctx, frame);
    if (rec_ret < 0 and rec_ret != c.AVERROR(c.EAGAIN)) {
        var err_buf: [128]u8 = undefined;
        _ = c.av_strerror(rec_ret, &err_buf, err_buf.len);
        std.debug.print("avcodec_receive_frame failed: {s}\n", .{err_buf});
        return error.ReceiveFrameFailed;
    }
}
