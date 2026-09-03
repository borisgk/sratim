const std = @import("std");
const tables = @import("tables.zig");
const bit_writer = @import("bit_writer.zig");
const mdct = @import("../mdct.zig");

pub const BitWriter = bit_writer.BitWriter;

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

        // 1. Prepare 2048-point windowed time samples scaled to 16-bit PCM domain (32768.0)
        const PCM_SCALE: f32 = 32768.0;
        var windowed_l: [2048]f32 = undefined;
        var windowed_r: [2048]f32 = undefined;

        const V4 = @Vector(4, f32);
        const v_scale: V4 = @splat(PCM_SCALE);
        var win_i: usize = 0;
        while (win_i < 1024) : (win_i += 4) {
            const v_win0: V4 = tables.SINE_WINDOW_2048[win_i..][0..4].*;
            const v_win1: V4 = tables.SINE_WINDOW_2048[1024 + win_i ..][0..4].*;
            const v_prev_l: V4 = self.prev_samples_l[win_i..][0..4].*;
            const v_prev_r: V4 = self.prev_samples_r[win_i..][0..4].*;
            const v_in_l: V4 = in_l[win_i..][0..4].*;
            const v_in_r: V4 = in_r[win_i..][0..4].*;

            windowed_l[win_i..][0..4].* = v_prev_l * v_scale * v_win0;
            windowed_r[win_i..][0..4].* = v_prev_r * v_scale * v_win0;
            windowed_l[1024 + win_i ..][0..4].* = v_in_l * v_scale * v_win1;
            windowed_r[1024 + win_i ..][0..4].* = v_in_r * v_scale * v_win1;
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
        var sf_l: [tables.NUM_SFBS]u8 = undefined;
        var sf_r: [tables.NUM_SFBS]u8 = undefined;

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
        try writer.writeBits(tables.NUM_SFBS, 6);
        // predictor_data_present = 0
        try writer.writeBit(0);

        // ms_mask_present = 0 (independent L/R)
        try writer.writeBits(0, 2);

        // Write Channel 0 (Left)
        try writeIndividualChannelStream(&writer, sf_l[0], sf_l[0..tables.NUM_SFBS], &quant_l);
        // Write Channel 1 (Right)
        try writeIndividualChannelStream(&writer, sf_r[0], sf_r[0..tables.NUM_SFBS], &quant_r);

        // ID_END (7)
        try writer.writeBits(7, 3);
        try writer.byteAlign();

        return writer.byteCount();
    }

    /// Formats a raw AAC frame into a 7-byte standard ADTS frame.
    pub fn buildAdtsHeader(frame_length: usize, sample_rate: u32, channel_count: u3) [7]u8 {
        var sample_idx: u4 = 3; // default 48000 Hz
        for (tables.FREQ_INDICES, 0..) |freq, idx| {
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

pub fn quantizeChannel(spec: []const f32, sf: []u8, quant: []i16) void {
    // Determine overall peak to seed initial global gain (vectorized @max + @reduce)
    var v_max: @Vector(4, f32) = @splat(0.0);
    var p_i: usize = 0;
    while (p_i < 1024) : (p_i += 4) {
        const v_chunk: @Vector(4, f32) = spec[p_i..][0..4].*;
        v_max = @max(v_max, @abs(v_chunk));
    }
    const global_max = @reduce(.Max, v_max);

    const SF_OFFSET: f64 = 80.0;

    const init_sf: u8 = if (global_max > 1e-4) blk: {
        const log2_m = std.math.log2(@as(f64, global_max));
        const raw = @as(i32, @intFromFloat(std.math.round(SF_OFFSET + 4.0 * log2_m)));
        break :blk @intCast(std.math.clamp(raw, 10, 240));
    } else 100;

    var prev_sf: u8 = init_sf;

    for (0..tables.NUM_SFBS) |b| {
        const start = tables.SWB_OFFSET_48000[b];
        const end = tables.SWB_OFFSET_48000[b + 1];

        // Zero out ultrasonic frequencies > 18 kHz (band 42+) to save bitrate and prevent noise
        if (b >= 42) {
            sf[b] = prev_sf;
            for (start..end) |k| quant[k] = 0;
            continue;
        }

        var max_val: f32 = 0.0;
        for (start..end) |k| {
            const val = @abs(spec[k]);
            if (val > max_val) max_val = val;
        }

        if (max_val < 1e-4) {
            sf[b] = prev_sf;
            for (start..end) |k| quant[k] = 0;
            continue;
        }

        const log2_max = std.math.log2(@as(f64, max_val));
        const raw_sf = @as(i32, @intFromFloat(std.math.round(SF_OFFSET + 4.0 * log2_max)));
        const target_sf: u8 = @intCast(std.math.clamp(raw_sf, 10, 240));

        // Allow full Huffman codebook range for band deltas (±60)
        const clamped_sf: u8 = @intCast(std.math.clamp(
            @as(i32, target_sf),
            @as(i32, prev_sf) - 60,
            @as(i32, prev_sf) + 60,
        ));
        sf[b] = clamped_sf;
        prev_sf = clamped_sf;

        // step_scale = 2^(-0.25 * (sf - 100))
        const step_scale = @as(f32, @floatCast(std.math.pow(f64, 2.0, -0.25 * (@as(f64, @floatFromInt(clamped_sf)) - 100.0))));

        const V = @Vector(4, f32);
        const VI = @Vector(4, i32);
        const v_step: V = @splat(step_scale);
        const v_threshold: V = @splat(0.01);
        const v_offset: V = @splat(0.4054);
        const v_zero_f: V = @splat(0.0);
        const v_zero_i: VI = @splat(0);
        const v_max_i: VI = @splat(8191);

        var k: usize = start;
        while (k + 4 <= end) : (k += 4) {
            const v_s: V = spec[k..][0..4].*;
            const v_abs = @abs(v_s);
            const v_scaled = v_abs * v_step;

            // x^0.75 = sqrt(x * sqrt(x)) using native hardware parallel square root
            const v_sqrt1 = @sqrt(v_scaled);
            const v_pow34 = @sqrt(v_scaled * v_sqrt1);
            const v_q_float = v_pow34 + v_offset;
            const v_q_int = @as(VI, @intFromFloat(v_q_float));
            const v_clamped = std.math.clamp(v_q_int, v_zero_i, v_max_i);

            const is_neg = v_s < v_zero_f;
            const v_signed = @select(i32, is_neg, -v_clamped, v_clamped);
            const is_small = v_scaled < v_threshold;
            const v_final = @select(i32, is_small, v_zero_i, v_signed);

            quant[k..][0..4].* = @as(@Vector(4, i16), @intCast(v_final));
        }

        while (k < end) : (k += 1) {
            const s = spec[k];
            const scaled = @abs(s) * step_scale;
            if (scaled < 0.01) {
                quant[k] = 0;
            } else {
                const q_float = std.math.pow(f32, scaled, 0.75) + 0.4054;
                const q = std.math.clamp(@as(i32, @intFromFloat(q_float)), 0, 8191);
                quant[k] = if (s < 0.0) @intCast(-q) else @intCast(q);
            }
        }
    }
}

pub fn writeIndividualChannelStream(
    writer: *BitWriter,
    global_gain: u8,
    sfs: []const u8,
    quant: []const i16,
) !void {
    // global_gain
    try writer.writeBits(global_gain, 8);

    // Section data:
    // All 49 scalefactor bands use Codebook 11 (Esc codebook).
    try writer.writeBits(11, 4); // Codebook 11
    try writer.writeBits(31, 5); // 31 (continuation escape)
    try writer.writeBits(tables.NUM_SFBS - 31, 5); // 18 (total section length = 49)

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
    try writer.writeBits(tables.SCALEFACTOR_CODES[idx], tables.SCALEFACTOR_BITS[idx]);
}

fn writeCodebook11Pair(writer: *BitWriter, x: i16, y: i16) !void {
    const ax: u32 = @intCast(@abs(x));
    const ay: u32 = @intCast(@abs(y));

    const qx: u32 = @min(ax, 16);
    const qy: u32 = @min(ay, 16);

    const idx: usize = @intCast(qx * 17 + qy);
    try writer.writeBits(tables.CB11_CODES[idx], tables.CB11_BITS[idx]);

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
    const coef: u32 = @min(val, 8191);
    if (coef < 16) return;
    const len = std.math.log2_int(u32, coef);
    const N = len - 4;
    const esc_len = N + 1;
    const esc_prefix: u32 = (@as(u32, 1) << @intCast(esc_len)) - 2;
    try writer.writeBits(esc_prefix, esc_len);
    const suffix: u32 = coef - (@as(u32, 1) << @intCast(len));
    try writer.writeBits(suffix, len);
}
