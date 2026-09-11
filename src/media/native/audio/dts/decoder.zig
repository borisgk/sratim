// Pure Zig DTS Core (DCA) Frame Decoder - ETSI TS 102 114
const std = @import("std");
const bit_reader_mod = @import("bit_reader.zig");
const BitReader = bit_reader_mod.BitReader;
const header_mod = @import("header.zig");
const FrameHeader = header_mod.FrameHeader;
const AudioMode = header_mod.AudioMode;
const tables = @import("tables.zig");
const synthesis = @import("synthesis.zig");
const SubbandDsp = synthesis.SubbandDsp;
const LfeDsp = synthesis.LfeDsp;
const subband = @import("subband.zig");
const SubbandDecoderState = subband.SubbandDecoderState;

pub const MAX_CHANNELS: usize = 8;
pub const MAX_PCM_SAMPLES: usize = 2048; // 64 blocks * 32

pub const Speaker = enum(usize) {
    center = 0,
    left = 1,
    right = 2,
    surround_left = 3,
    surround_right = 4,
    surround_center = 5,
    lfe = 6,
    none = 7,
};

pub const DtsDecoder = struct {
    allocator: std.mem.Allocator,
    subband_dsp: [MAX_CHANNELS]SubbandDsp,
    lfe_dsp: LfeDsp,
    subband_state: SubbandDecoderState,
    channel_pcm: [7][MAX_PCM_SAMPLES]f32,
    staged_buf: [16384]u8,
    last_header: ?FrameHeader = null,

    pub fn init() DtsDecoder {
        var dec: DtsDecoder = undefined;
        for (0..MAX_CHANNELS) |ch| {
            dec.subband_dsp[ch] = SubbandDsp.init();
        }
        dec.lfe_dsp = LfeDsp.init();
        dec.subband_state = SubbandDecoderState.init();
        @memset(std.mem.asBytes(&dec.channel_pcm), 0);
        dec.last_header = null;
        return dec;
    }

    pub fn reset(self: *DtsDecoder) void {
        for (0..MAX_CHANNELS) |ch| {
            self.subband_dsp[ch].reset();
        }
        self.lfe_dsp.reset();
        self.subband_state.reset();
        self.last_header = null;
    }

    fn mapPrmChToSpeaker(mode: AudioMode, ch: usize) Speaker {
        return switch (mode) {
            .mono => if (ch == 0) .center else .none,
            .dual_mono, .stereo, .stereo_sumdiff, .stereo_total => switch (ch) {
                0 => .left,
                1 => .right,
                else => .none,
            },
            .surround_3_0 => switch (ch) {
                0 => .center,
                1 => .left,
                2 => .right,
                else => .none,
            },
            .surround_2_1 => switch (ch) {
                0 => .left,
                1 => .right,
                2 => .surround_center,
                else => .none,
            },
            .surround_3_1 => switch (ch) {
                0 => .center,
                1 => .left,
                2 => .right,
                3 => .surround_center,
                else => .none,
            },
            .surround_2_2 => switch (ch) {
                0 => .left,
                1 => .right,
                2 => .surround_left,
                3 => .surround_right,
                else => .none,
            },
            .surround_5_0 => switch (ch) {
                0 => .center,
                1 => .left,
                2 => .right,
                3 => .surround_left,
                4 => .surround_right,
                else => .none,
            },
            _ => switch (ch) {
                0 => .left,
                1 => .right,
                else => .none,
            },
        };
    }

    /// Decodes a DTS frame into interleaved float32 stereo PCM.
    /// Returns the number of stereo samples per channel produced.
    pub fn decodeFrame(self: *DtsDecoder, input_frame: []const u8, out_stereo_pcm: []f32) !usize {
        const sync_info = header_mod.findSync(input_frame) orelse return error.SyncNotFound;
        var frame_slice = input_frame[sync_info.offset..];

        if (sync_info.is_14bit) {
            if (sync_info.is_le) {
                // 14-bit LE: byte swap 16-bit words first
                const swap_len = @min(frame_slice.len & ~@as(usize, 1), self.staged_buf.len);
                var i: usize = 0;
                while (i < swap_len) : (i += 2) {
                    self.staged_buf[i] = frame_slice[i + 1];
                    self.staged_buf[i + 1] = frame_slice[i];
                }
                const unpacked_len = header_mod.unpack14Bit(self.staged_buf[0..swap_len], &self.staged_buf);
                frame_slice = self.staged_buf[0..unpacked_len];
            } else {
                const unpacked_len = header_mod.unpack14Bit(frame_slice, &self.staged_buf);
                frame_slice = self.staged_buf[0..unpacked_len];
            }
        } else if (sync_info.is_le) {
            // 16-bit LE: byte swap
            const swap_len = @min(frame_slice.len & ~@as(usize, 1), self.staged_buf.len);
            var i: usize = 0;
            while (i < swap_len) : (i += 2) {
                self.staged_buf[i] = frame_slice[i + 1];
                self.staged_buf[i + 1] = frame_slice[i];
            }
            frame_slice = self.staged_buf[0..swap_len];
        }

        var reader = BitReader.init(frame_slice);
        const hdr = try header_mod.parseHeader(&reader);
        self.last_header = hdr;

        const npcmblocks: usize = hdr.npcmblocks;
        const total_samples: usize = npcmblocks * 32;
        if (out_stereo_pcm.len < total_samples * 2) {
            return error.OutputBufferTooSmall;
        }

        // Initialize subband decoding state
        if (!hdr.predictor_history) {
            // Erase ADPCM history
            for (0..hdr.nchannels) |ch| {
                for (0..32) |b| {
                    @memset(&self.subband_state.subband_samples[ch][b], 0);
                }
            }
        }

        var sub_pos: usize = 0;
        var lfe_pos: usize = synthesis.MAX_LFE_HISTORY;
        if (hdr.lfe_present != 0) {
            @memcpy(self.subband_state.lfe_samples[0..8], &self.lfe_dsp.history);
        }

        // Decode subframes
        for (0..hdr.nsubframes) |sf| {
            try self.subband_state.decodeSubframe(&reader, &hdr, sf, &sub_pos, &lfe_pos);
        }

        // Carry over ADPCM history for next frame
        for (0..hdr.nchannels) |ch| {
            var nsubbands = hdr.nsubbands[ch];
            if (hdr.joint_intensity_index[ch] != 0) {
                const src_ch = hdr.joint_intensity_index[ch] - 1;
                nsubbands = @max(nsubbands, hdr.nsubbands[src_ch]);
            }
            for (0..nsubbands) |b| {
                const end_offset = subband.NUM_ADPCM_COEFFS + npcmblocks;
                @memcpy(
                    self.subband_state.subband_samples[ch][b][0..subband.NUM_ADPCM_COEFFS],
                    self.subband_state.subband_samples[ch][b][end_offset - subband.NUM_ADPCM_COEFFS .. end_offset],
                );
            }
            // Clear unused subbands
            for (nsubbands..32) |b| {
                @memset(&self.subband_state.subband_samples[ch][b], 0);
            }
        }

        // Filterbank synthesis per channel
        @memset(std.mem.asBytes(&self.channel_pcm), 0);
        for (0..hdr.nchannels) |ch| {
            const spkr = mapPrmChToSpeaker(hdr.audio_mode, ch);
            if (spkr != .none) {
                const spkr_idx = @intFromEnum(spkr);
                self.subband_dsp[ch].interpolateSub32(
                    &self.subband_state.subband_samples[ch],
                    npcmblocks,
                    hdr.filter_perfect,
                    self.channel_pcm[spkr_idx][0..total_samples],
                );
            }
        }

        // LFE synthesis
        const has_lfe = (hdr.lfe_present != 0);
        if (has_lfe) {
            const dec_select = (hdr.lfe_present == 2);
            self.lfe_dsp.interpolateLfe(
                &self.subband_state.lfe_samples,
                npcmblocks,
                dec_select,
                self.channel_pcm[@intFromEnum(Speaker.lfe)][0..total_samples],
            );
        }

        // Front sum/diff decoding
        if ((hdr.sumdiff_front and hdr.audio_mode != .mono) or hdr.audio_mode == .stereo_sumdiff) {
            const l_idx = @intFromEnum(Speaker.left);
            const r_idx = @intFromEnum(Speaker.right);
            for (0..total_samples) |n| {
                const l = self.channel_pcm[l_idx][n];
                const r = self.channel_pcm[r_idx][n];
                self.channel_pcm[l_idx][n] = l + r;
                self.channel_pcm[r_idx][n] = l - r;
            }
        }

        // Surround sum/diff decoding
        if (hdr.sumdiff_surround and @intFromEnum(hdr.audio_mode) >= @intFromEnum(AudioMode.surround_2_2)) {
            const ls_idx = @intFromEnum(Speaker.surround_left);
            const rs_idx = @intFromEnum(Speaker.surround_right);
            for (0..total_samples) |n| {
                const ls = self.channel_pcm[ls_idx][n];
                const rs = self.channel_pcm[rs_idx][n];
                self.channel_pcm[ls_idx][n] = ls + rs;
                self.channel_pcm[rs_idx][n] = ls - rs;
            }
        }

        // Downmixing to stereo output using ITU-R BS.775 with LFE (-3dB)
        const INV_SQRT2: f32 = 0.70710678;
        const c_idx = @intFromEnum(Speaker.center);
        const l_idx = @intFromEnum(Speaker.left);
        const r_idx = @intFromEnum(Speaker.right);
        const ls_idx = @intFromEnum(Speaker.surround_left);
        const rs_idx = @intFromEnum(Speaker.surround_right);
        const cs_idx = @intFromEnum(Speaker.surround_center);
        const lfe_idx = @intFromEnum(Speaker.lfe);

        switch (hdr.audio_mode) {
            .mono => {
                for (0..total_samples) |n| {
                    const c = self.channel_pcm[c_idx][n];
                    const lfe = if (has_lfe) self.channel_pcm[lfe_idx][n] * INV_SQRT2 else 0.0;
                    const val = std.math.clamp(c + lfe, -1.0, 1.0);
                    out_stereo_pcm[2 * n] = val;
                    out_stereo_pcm[2 * n + 1] = val;
                }
            },
            .surround_5_0 => {
                for (0..total_samples) |n| {
                    const c = self.channel_pcm[c_idx][n] * INV_SQRT2;
                    const l = self.channel_pcm[l_idx][n];
                    const r = self.channel_pcm[r_idx][n];
                    const ls = self.channel_pcm[ls_idx][n] * INV_SQRT2;
                    const rs = self.channel_pcm[rs_idx][n] * INV_SQRT2;
                    const lfe = if (has_lfe) self.channel_pcm[lfe_idx][n] * INV_SQRT2 else 0.0;

                    out_stereo_pcm[2 * n] = std.math.clamp(l + c + ls + lfe, -1.0, 1.0);
                    out_stereo_pcm[2 * n + 1] = std.math.clamp(r + c + rs + lfe, -1.0, 1.0);
                }
            },
            .surround_3_0 => {
                for (0..total_samples) |n| {
                    const c = self.channel_pcm[c_idx][n] * INV_SQRT2;
                    const l = self.channel_pcm[l_idx][n];
                    const r = self.channel_pcm[r_idx][n];
                    const lfe = if (has_lfe) self.channel_pcm[lfe_idx][n] * INV_SQRT2 else 0.0;

                    out_stereo_pcm[2 * n] = std.math.clamp(l + c + lfe, -1.0, 1.0);
                    out_stereo_pcm[2 * n + 1] = std.math.clamp(r + c + lfe, -1.0, 1.0);
                }
            },
            .surround_2_2 => {
                for (0..total_samples) |n| {
                    const l = self.channel_pcm[l_idx][n];
                    const r = self.channel_pcm[r_idx][n];
                    const ls = self.channel_pcm[ls_idx][n] * INV_SQRT2;
                    const rs = self.channel_pcm[rs_idx][n] * INV_SQRT2;
                    const lfe = if (has_lfe) self.channel_pcm[lfe_idx][n] * INV_SQRT2 else 0.0;

                    out_stereo_pcm[2 * n] = std.math.clamp(l + ls + lfe, -1.0, 1.0);
                    out_stereo_pcm[2 * n + 1] = std.math.clamp(r + rs + lfe, -1.0, 1.0);
                }
            },
            .surround_2_1 => {
                for (0..total_samples) |n| {
                    const l = self.channel_pcm[l_idx][n];
                    const r = self.channel_pcm[r_idx][n];
                    const cs = self.channel_pcm[cs_idx][n] * INV_SQRT2;
                    const lfe = if (has_lfe) self.channel_pcm[lfe_idx][n] * INV_SQRT2 else 0.0;

                    out_stereo_pcm[2 * n] = std.math.clamp(l + cs + lfe, -1.0, 1.0);
                    out_stereo_pcm[2 * n + 1] = std.math.clamp(r + cs + lfe, -1.0, 1.0);
                }
            },
            .surround_3_1 => {
                for (0..total_samples) |n| {
                    const c = self.channel_pcm[c_idx][n] * INV_SQRT2;
                    const l = self.channel_pcm[l_idx][n];
                    const r = self.channel_pcm[r_idx][n];
                    const cs = self.channel_pcm[cs_idx][n] * INV_SQRT2;
                    const lfe = if (has_lfe) self.channel_pcm[lfe_idx][n] * INV_SQRT2 else 0.0;

                    out_stereo_pcm[2 * n] = std.math.clamp(l + c + cs + lfe, -1.0, 1.0);
                    out_stereo_pcm[2 * n + 1] = std.math.clamp(r + c + cs + lfe, -1.0, 1.0);
                }
            },
            else => {
                for (0..total_samples) |n| {
                    const l = self.channel_pcm[l_idx][n];
                    const r = self.channel_pcm[r_idx][n];
                    const lfe = if (has_lfe) self.channel_pcm[lfe_idx][n] * INV_SQRT2 else 0.0;

                    out_stereo_pcm[2 * n] = std.math.clamp(l + lfe, -1.0, 1.0);
                    out_stereo_pcm[2 * n + 1] = std.math.clamp(r + lfe, -1.0, 1.0);
                }
            },
        }

        return total_samples;
    }
};
