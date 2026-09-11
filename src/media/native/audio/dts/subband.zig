// Pure Zig DTS Core (DCA) Subband and Subframe Processing - ETSI TS 102 114
const std = @import("std");
const tables = @import("tables.zig");
const vectors = @import("vectors.zig");
const bit_reader_mod = @import("bit_reader.zig");
const BitReader = bit_reader_mod.BitReader;
const header_mod = @import("header.zig");
const FrameHeader = header_mod.FrameHeader;

pub const NUM_SUBBAND_SAMPLES: usize = 8;
pub const NUM_ADPCM_COEFFS: usize = 4;
pub const MAX_PCM_BLOCKS: usize = 64;
pub const MAX_LFE_SAMPLES: usize = 32;

pub inline fn clip23(v: i64) i32 {
    if (v > 8388607) return 8388607;
    if (v < -8388608) return -8388608;
    return @intCast(v);
}

pub inline fn norm__(a: i64, bits: i32) i32 {
    if (bits > 0) {
        const ubits: u6 = @intCast(bits);
        const half = @as(i64, 1) << (ubits - 1);
        return @intCast((a + half) >> ubits);
    } else {
        return @intCast(a);
    }
}

pub inline fn norm13(a: i64) i32 {
    return norm__(a, 13);
}

pub inline fn mul4(a: i32, b: i32) i32 {
    return @intCast((@as(i64, a) * @as(i64, b) + 8) >> 4);
}

pub inline fn mul17(a: i32, b: i32) i32 {
    return norm__(@as(i64, a) * @as(i64, b), 17);
}

pub inline fn mul23(a: i32, b: i32) i32 {
    return norm__(@as(i64, a) * @as(i64, b), 23);
}

pub fn parseScale(reader: *BitReader, scale_index: *i32, sel: u3) !i32 {
    const scale_table: []const i32 = if (sel > 5) &tables.scale_factors_7bit else &tables.scale_factors_6bit;
    if (sel < 5) {
        const diff = try reader.readVlcSigned(&tables.scale_factor_huff[sel]);
        scale_index.* +%= diff;
    } else {
        scale_index.* = @intCast(try reader.readBits(u32, sel + 1));
    }
    if (scale_index.* < 0 or scale_index.* >= scale_table.len) {
        return error.InvalidScaleIndex;
    }
    return scale_table[@intCast(scale_index.*)];
}

pub fn parseJointScale(reader: *BitReader, sel: u3) !i32 {
    var scale_index: i32 = undefined;
    if (sel < 5) {
        scale_index = try reader.readVlcSigned(&tables.scale_factor_huff[sel]);
    } else {
        scale_index = @intCast(try reader.readBits(u32, sel + 1));
    }
    scale_index += 64;
    if (scale_index < 0 or scale_index >= tables.joint_scale_factors.len) {
        return error.InvalidJointScaleIndex;
    }
    return tables.joint_scale_factors[@intCast(scale_index)];
}

pub fn parseBlockCodes(reader: *BitReader, audio: *[8]i32, abits: usize) !void {
    const nbits = tables.block_code_nbits[abits];
    var code1: i32 = @intCast(try reader.readBits(u32, nbits));
    var code2: i32 = @intCast(try reader.readBits(u32, nbits));
    const levels = tables.quant_levels[abits];
    const offset = @divFloor(levels - 1, 2);

    for (0..4) |n| {
        audio[n] = @rem(code1, levels) - offset;
        code1 = @divFloor(code1, levels);
    }
    for (4..8) |n| {
        audio[n] = @rem(code2, levels) - offset;
        code2 = @divFloor(code2, levels);
    }
    if (code1 != 0 or code2 != 0) {
        return error.FailedToDecodeBlockCodes;
    }
}

pub fn extractAudio(reader: *BitReader, audio: *[8]i32, abits: usize, quant_index_sel: ?u8) !u1 {
    if (abits == 0) {
        @memset(audio, 0);
        return 0;
    }
    if (abits <= 10) {
        if (quant_index_sel) |sel| {
            if (sel < tables.quant_index_group_size[abits - 1]) {
                for (0..8) |n| {
                    audio[n] = try reader.readVlcSigned(&tables.quant_index_group_huff[abits - 1][sel]);
                }
                return 1;
            }
        }
        if (abits <= 7) {
            try parseBlockCodes(reader, audio, abits);
            return 0;
        }
    }
    for (0..8) |n| {
        audio[n] = try reader.readSignedBits(abits - 3);
    }
    return 0;
}

pub inline fn dequantize(output: []i32, audio: *const [8]i32, step_size: i32, scale_val: i32) void {
    var step_scale: i64 = @as(i64, step_size) * @as(i64, scale_val);
    var shift: i32 = 0;
    if (step_scale > (1 << 23)) {
        const high_part = @as(u32, @intCast(step_scale >> 23));
        shift = @as(i32, 32) - @as(i32, @intCast(@clz(high_part)));
        step_scale >>= @intCast(shift);
    }
    for (0..8) |n| {
        output[n] = clip23(norm__(@as(i64, audio[n]) * step_scale, 22 - shift));
    }
}

pub const SubbandDecoderState = struct {
    subband_samples: [8][32][NUM_ADPCM_COEFFS + MAX_PCM_BLOCKS]i32,
    lfe_samples: [8 + MAX_LFE_SAMPLES]i32,

    prediction_mode: [8][32]bool,
    prediction_vq_index: [8][32]u12,
    bit_allocation: [8][32]u8,
    transition_mode: [8][32]u2,
    scale_factors: [8][32][2]i32,
    joint_scale_sel: [8]u3,
    joint_scale_factors: [8][32]i32,

    pub fn init() SubbandDecoderState {
        var s: SubbandDecoderState = undefined;
        s.reset();
        return s;
    }

    pub fn reset(self: *SubbandDecoderState) void {
        @memset(std.mem.asBytes(&self.subband_samples), 0);
        @memset(std.mem.asBytes(&self.lfe_samples), 0);
        @memset(std.mem.asBytes(&self.prediction_mode), 0);
        @memset(std.mem.asBytes(&self.prediction_vq_index), 0);
        @memset(std.mem.asBytes(&self.bit_allocation), 0);
        @memset(std.mem.asBytes(&self.transition_mode), 0);
        @memset(std.mem.asBytes(&self.scale_factors), 0);
        @memset(std.mem.asBytes(&self.joint_scale_sel), 0);
        @memset(std.mem.asBytes(&self.joint_scale_factors), 0);
    }

    pub fn decodeSubframe(
        self: *SubbandDecoderState,
        reader: *BitReader,
        hdr: *const FrameHeader,
        sf_idx: usize,
        sub_pos: *usize,
        lfe_pos: *usize,
    ) !void {
        _ = sf_idx;
        // Subframe header
        const nsubsubframes: usize = @as(usize, try reader.readBits(u2, 2)) + 1;
        try reader.skipBits(3); // partial subsubframe sample count

        // Prediction mode
        for (0..hdr.nchannels) |ch| {
            for (0..hdr.nsubbands[ch]) |b| {
                self.prediction_mode[ch][b] = (try reader.readBit()) != 0;
            }
        }

        // Prediction coefficients VQ address
        for (0..hdr.nchannels) |ch| {
            for (0..hdr.nsubbands[ch]) |b| {
                if (self.prediction_mode[ch][b]) {
                    self.prediction_vq_index[ch][b] = try reader.readBits(u12, 12);
                }
            }
        }

        // Bit allocation index
        for (0..hdr.nchannels) |ch| {
            const sel = hdr.bit_allocation_sel[ch];
            for (0..hdr.subband_vq_start[ch]) |b| {
                var abits: usize = 0;
                if (sel < 5) {
                    abits = (try reader.readVlcUnsigned(&tables.bit_allocation_huff[sel])) + 1;
                } else {
                    abits = try reader.readBits(u5, sel - 1);
                }
                if (abits >= 27) return error.InvalidBitAllocationIndex;
                self.bit_allocation[ch][b] = @intCast(abits);
            }
        }

        // Transition mode
        for (0..hdr.nchannels) |ch| {
            @memset(&self.transition_mode[ch], 0);
            if (nsubsubframes > 1) {
                const sel = hdr.transition_mode_sel[ch];
                for (0..hdr.subband_vq_start[ch]) |b| {
                    if (self.bit_allocation[ch][b] != 0) {
                        const trans_ssf = try reader.readVlcUnsigned(&tables.transition_mode_huff[sel]);
                        if (trans_ssf >= 4) return error.InvalidTransitionModeIndex;
                        self.transition_mode[ch][b] = @intCast(trans_ssf);
                    }
                }
            }
        }

        // Scale factors
        for (0..hdr.nchannels) |ch| {
            const sel = hdr.scale_factor_sel[ch];
            var scale_index: i32 = 0;
            for (0..hdr.subband_vq_start[ch]) |b| {
                if (self.bit_allocation[ch][b] != 0) {
                    self.scale_factors[ch][b][0] = try parseScale(reader, &scale_index, sel);
                    if (self.transition_mode[ch][b] != 0) {
                        self.scale_factors[ch][b][1] = try parseScale(reader, &scale_index, sel);
                    }
                } else {
                    self.scale_factors[ch][b][0] = 0;
                }
            }

            for (hdr.subband_vq_start[ch]..hdr.nsubbands[ch]) |b| {
                self.scale_factors[ch][b][0] = try parseScale(reader, &scale_index, sel);
            }
        }

        // Joint subband codebook select
        for (0..hdr.nchannels) |ch| {
            if (hdr.joint_intensity_index[ch] != 0) {
                const j_sel = try reader.readBits(u3, 3);
                if (j_sel == 7) return error.InvalidJointScaleFactor;
                self.joint_scale_sel[ch] = j_sel;
            }
        }

        // Joint subband scale factors
        for (0..hdr.nchannels) |ch| {
            if (hdr.joint_intensity_index[ch] != 0) {
                const sel = self.joint_scale_sel[ch];
                const src_ch = hdr.joint_intensity_index[ch] - 1;
                for (hdr.nsubbands[ch]..hdr.nsubbands[src_ch]) |b| {
                    self.joint_scale_factors[ch][b] = try parseJointScale(reader, sel);
                }
            }
        }

        // DRC & CRC
        if (hdr.drc_present) try reader.skipBits(8);
        if (hdr.crc_present) try reader.skipBits(16);

        // Subframe audio data
        const nsamples = nsubsubframes * NUM_SUBBAND_SAMPLES;
        if (sub_pos.* + nsamples > hdr.npcmblocks) return error.SubbandSampleBufferOverflow;

        // VQ encoded subbands
        for (0..hdr.nchannels) |ch| {
            for (hdr.subband_vq_start[ch]..hdr.nsubbands[ch]) |b| {
                const vq_idx = try reader.readBits(u10, 10);
                const scale_val = self.scale_factors[ch][b][0];
                const vq_samples = &vectors.high_freq_samples[vq_idx];
                for (0..nsamples) |n| {
                    self.subband_samples[ch][b][NUM_ADPCM_COEFFS + sub_pos.* + n] = clip23(mul4(scale_val, vq_samples[n]));
                }
            }
        }

        // LFE data
        if (hdr.lfe_present != 0) {
            const nlfesamples = 2 * @as(usize, hdr.lfe_present) * nsubsubframes;
            var audio_lfe: [MAX_LFE_SAMPLES]i32 = undefined;
            for (0..nlfesamples) |n| {
                audio_lfe[n] = try reader.readSignedBits(8);
            }
            const scale_idx = try reader.readBits(u8, 8);
            if (scale_idx >= tables.scale_factors_7bit.len) return error.InvalidLfeScaleFactor;
            const lfe_scale = tables.scale_factors_7bit[scale_idx];
            const step_scale = mul23(4697620, lfe_scale);
            for (0..nlfesamples) |n| {
                self.lfe_samples[lfe_pos.* + n] = clip23((audio_lfe[n] * step_scale) >> 4);
            }
            lfe_pos.* += nlfesamples;
        }

        // Audio data
        var ofs = sub_pos.*;
        for (0..nsubsubframes) |ssf| {
            for (0..hdr.nchannels) |ch| {
                for (0..hdr.subband_vq_start[ch]) |b| {
                    const abits = self.bit_allocation[ch][b];
                    var audio: [NUM_SUBBAND_SAMPLES]i32 = undefined;
                    const quant_sel: ?u8 = if (abits >= 1 and abits <= 10) hdr.quant_index_sel[ch][abits - 1] else null;
                    const ret = try extractAudio(reader, &audio, abits, quant_sel);

                    const step_size: i32 = if (hdr.bit_rate == -2) tables.step_size_lossless[abits] else tables.step_size_lossy[abits];
                    const trans_ssf = self.transition_mode[ch][b];
                    var scale_val: i32 = if (trans_ssf == 0 or ssf < trans_ssf) self.scale_factors[ch][b][0] else self.scale_factors[ch][b][1];
                    if (ret > 0 and abits >= 1 and abits <= 10) {
                        const adj = hdr.scale_factor_adj[ch][abits - 1];
                        scale_val = clip23((@as(i64, adj) * @as(i64, scale_val)) >> 22);
                    }

                    dequantize(
                        self.subband_samples[ch][b][NUM_ADPCM_COEFFS + ofs .. NUM_ADPCM_COEFFS + ofs + 8],
                        &audio,
                        step_size,
                        scale_val,
                    );
                }
            }

            // DSYNC
            if (ssf == nsubsubframes - 1 or hdr.sync_ssf) {
                const dsync = try reader.readBits(u16, 16);
                if (dsync != 0xFFFF) return error.DsyncCheckFailed;
            }
            ofs += NUM_SUBBAND_SAMPLES;
        }

        // Inverse ADPCM
        for (0..hdr.nchannels) |ch| {
            for (0..hdr.nsubbands[ch]) |b| {
                if (self.prediction_mode[ch][b]) {
                    const vq_idx = self.prediction_vq_index[ch][b];
                    const vq_coeffs = &vectors.adpcm_coeffs[vq_idx];
                    const base_idx = NUM_ADPCM_COEFFS + sub_pos.*;

                    for (0..nsamples) |m| {
                        var err: i64 = 0;
                        for (0..4) |k| {
                            const prev_sample = self.subband_samples[ch][b][base_idx + m - k - 1];
                            err += @as(i64, vq_coeffs[k]) * @as(i64, prev_sample);
                        }
                        self.subband_samples[ch][b][base_idx + m] = clip23(self.subband_samples[ch][b][base_idx + m] + clip23(norm13(err)));
                    }
                }
            }
        }

        // Joint subbands
        for (0..hdr.nchannels) |ch| {
            if (hdr.joint_intensity_index[ch] != 0) {
                const src_ch = hdr.joint_intensity_index[ch] - 1;
                for (hdr.nsubbands[ch]..hdr.nsubbands[src_ch]) |b| {
                    const scale_val = self.joint_scale_factors[ch][b];
                    for (0..nsamples) |n| {
                        const src_val = self.subband_samples[src_ch][b][NUM_ADPCM_COEFFS + sub_pos.* + n];
                        self.subband_samples[ch][b][NUM_ADPCM_COEFFS + sub_pos.* + n] = clip23(mul17(src_val, scale_val));
                    }
                }
            }
        }

        sub_pos.* += nsamples;
    }
};

test "clip23 and fixed math sanity" {
    try std.testing.expectEqual(@as(i32, 8388607), clip23(10000000));
    try std.testing.expectEqual(@as(i32, -8388608), clip23(-10000000));
    try std.testing.expectEqual(@as(i32, 100), clip23(100));
    try std.testing.expectEqual(@as(i32, 2), norm__(16, 3));
}
