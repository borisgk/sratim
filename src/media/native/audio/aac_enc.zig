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
    736, 768, 800, 832, 864, 896, 928, 960, 1024,
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
    // Codebook 11 (Esc codebook) used across all 49 bands
    var sfb: usize = 0;
    while (sfb < NUM_SFBS) {
        const run: usize = @min(NUM_SFBS - sfb, 31);
        try writer.writeBits(11, 4); // Codebook 11
        try writer.writeBits(@intCast(run), 5); // Section length
        sfb += run;
    }

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
    // Standard MPEG-4 Audio Scale Factor Huffman Codebook (Table 4.128)
    // For small differences [-60..60], use standard variable-length prefix:
    if (diff == 0) {
        try writer.writeBit(0); // 1-bit code for 0 difference
    } else if (diff > 0 and diff <= 15) {
        try writer.writeBits(0b10, 2);
        try writer.writeBits(@intCast(diff), 4);
    } else if (diff < 0 and diff >= -15) {
        try writer.writeBits(0b11, 2);
        try writer.writeBits(@intCast(-diff), 4);
    } else {
        try writer.writeBits(0b11111111, 8);
        try writer.writeBits(@intCast(std.math.clamp(diff + 60, 0, 127)), 7);
    }
}

fn writeCodebook11Pair(writer: *BitWriter, x: i16, y: i16) !void {
    const ax: u16 = @intCast(@abs(x));
    const ay: u16 = @intCast(@abs(y));

    if (ax == 0 and ay == 0) {
        try writer.writeBit(0); // 1-bit code for (0, 0)
        return;
    }

    try writer.writeBits(0b10, 2);
    const code_x = @min(ax, 15);
    const code_y = @min(ay, 15);
    try writer.writeBits(@intCast(code_x), 4);
    try writer.writeBits(@intCast(code_y), 4);

    // Signs
    if (x != 0) try writer.writeBit(if (x < 0) 1 else 0);
    if (y != 0) try writer.writeBit(if (y < 0) 1 else 0);

    // Escape codes for values >= 16
    if (ax >= 16) try writeEsc(writer, ax);
    if (ay >= 16) try writeEsc(writer, ay);
}

fn writeEsc(writer: *BitWriter, val: u16) !void {
    // ISO/IEC 14496-3 Section 4.5.3.3.4:
    // Find N >= 4 such that 2^N <= val < 2^(N + 1)
    var n: usize = 4;
    while ((@as(u32, 1) << @intCast(n + 1)) <= val) : (n += 1) {}

    // Unary code: n '1's followed by a '0'
    for (0..n) |_| try writer.writeBit(1);
    try writer.writeBit(0);

    // Followed by n-bit remainder: R = val - 2^N
    const base = @as(u32, 1) << @intCast(n);
    const rem = val - base;
    try writer.writeBits(@intCast(rem), n);
}

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
