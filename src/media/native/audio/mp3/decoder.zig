const std = @import("std");
const tables = @import("tables.zig");
const bit_reader = @import("bit_reader.zig");
const huffman = @import("huffman.zig");
const imdct_mod = @import("imdct.zig");
const synthesis_mod = @import("synthesis.zig");

pub const Mp3Decoder = struct {
    sample_rate: u32 = 44100,
    channels: u16 = 2,
    bitrate_kbps: u16 = 128,
    mpeg_version: tables.MpegVersion = .mpeg1,
    channel_mode: tables.ChannelMode = .joint_stereo,
    mode_extension: u2 = 0,

    imdct: imdct_mod.ImdctState = imdct_mod.ImdctState.init(),
    synth: synthesis_mod.SynthesisFilterbank = synthesis_mod.SynthesisFilterbank.init(),

    /// Sliding bit reservoir buffer
    reservoir: [8192]u8 = undefined,
    reservoir_len: usize = 0,

    pub fn init() Mp3Decoder {
        return .{};
    }

    pub fn reset(self: *Mp3Decoder) void {
        self.imdct.reset();
        self.synth.reset();
        self.reservoir_len = 0;
    }

    /// Decodes an MP3 frame into interleaved stereo 32-bit float PCM samples.
    /// out_interleaved must have room for at least 1152 * 2 samples.
    /// Returns the number of PCM samples decoded (typically 1152 for MPEG-1, 576 for MPEG-2).
    pub fn decodeFrame(
        self: *Mp3Decoder,
        in_payload: []const u8,
        out_interleaved: []f32,
    ) !usize {
        if (in_payload.len < 4) return error.BufferTooSmall;

        // 1. Locate sync word (0xFFE or 0xFFF)
        var sync_pos: usize = 0;
        var found_sync = false;
        while (sync_pos + 4 <= in_payload.len) : (sync_pos += 1) {
            if (in_payload[sync_pos] == 0xFF and (in_payload[sync_pos + 1] & 0xE0) == 0xE0) {
                found_sync = true;
                break;
            }
        }
        if (!found_sync) return error.SyncNotFound;

        const header_bytes = in_payload[sync_pos .. sync_pos + 4];
        const ver_raw: u2 = @truncate((header_bytes[1] >> 3) & 0x03);
        const layer_raw: u2 = @truncate((header_bytes[1] >> 1) & 0x03);
        const protection_bit = (header_bytes[1] & 0x01) == 0;
        const bitrate_idx: u4 = @truncate(header_bytes[2] >> 4);
        const srate_idx: u2 = @truncate((header_bytes[2] >> 2) & 0x03);
        const padding_bit: u1 = @truncate((header_bytes[2] >> 1) & 0x01);
        const mode_raw: u2 = @truncate(header_bytes[3] >> 6);
        const mode_ext: u2 = @truncate((header_bytes[3] >> 4) & 0x03);

        const version: tables.MpegVersion = @enumFromInt(ver_raw);
        const layer: tables.MpegLayer = @enumFromInt(layer_raw);

        // We specifically decode Layer III
        if (layer != .layer3 or srate_idx == 3 or bitrate_idx == 15) {
            return error.UnsupportedMpegLayer;
        }

        const srate = tables.SAMPLE_RATES[@intFromEnum(version)][srate_idx];
        const bitrate = tables.BITRATES_LAYER3[@intFromEnum(version)][bitrate_idx];
        if (srate == 0 or bitrate == 0) return error.InvalidHeaderParameters;

        self.sample_rate = srate;
        self.bitrate_kbps = bitrate;
        self.mpeg_version = version;
        self.channel_mode = @enumFromInt(mode_raw);
        self.mode_extension = mode_ext;
        self.channels = if (self.channel_mode == .single_channel) 1 else 2;

        const is_mpeg1 = (version == .mpeg1);
        const n_granules: usize = if (is_mpeg1) 2 else 1;
        const n_channels: usize = self.channels;

        // Compute frame length in bytes
        const frame_len: usize = if (is_mpeg1)
            (144 * @as(usize, bitrate) * 1000) / srate + padding_bit
        else
            (72 * @as(usize, bitrate) * 1000) / srate + padding_bit;

        var header_offset: usize = sync_pos + 4;
        if (protection_bit) {
            header_offset += 2; // Skip 16-bit CRC
        }

        const side_info_len: usize = if (is_mpeg1)
            (if (n_channels == 1) 17 else 32)
        else
            (if (n_channels == 1) 9 else 17);

        if (in_payload.len < header_offset + side_info_len) {
            return error.IncompleteFrame;
        }

        // 2. Parse Side Information
        const side_bytes = in_payload[header_offset .. header_offset + side_info_len];
        var sbr = bit_reader.BitReader.init(side_bytes);

        const main_data_begin = if (is_mpeg1)
            try sbr.readBits(u9, 9)
        else
            try sbr.readBits(u8, 8);

        _ = if (n_channels == 1)
            try sbr.readBits(u5, 5)
        else
            try sbr.readBits(u3, 3); // private bits

        var scfsi: [2][4]u1 = undefined;
        if (is_mpeg1) {
            for (0..n_channels) |ch| {
                for (0..4) |scf| {
                    scfsi[ch][scf] = try sbr.readBit();
                }
            }
        }

        // Granule channel side info
        const GranuleChannel = struct {
            part2_3_length: u12,
            big_values: u9,
            global_gain: u8,
            scalefac_compress: u9,
            window_switching_flag: bool,
            block_type: u2,
            mixed_block_flag: bool,
            table_select: [3]u5,
            subblock_gain: [3]u3,
            region0_count: u4,
            region1_count: u3,
            preflag: u1,
            scalefac_scale: u1,
            count1table_select: u1,
        };

        var gr_ch: [2][2]GranuleChannel = undefined;

        for (0..n_granules) |gr| {
            for (0..n_channels) |ch| {
                const part2_3_len = try sbr.readBits(u12, 12);
                const big_vals = try sbr.readBits(u9, 9);
                const gain = try sbr.readBits(u8, 8);
                const scf_compress = if (is_mpeg1)
                    try sbr.readBits(u9, 4)
                else
                    try sbr.readBits(u9, 9);
                const win_switch = (try sbr.readBit() == 1);

                var b_type: u2 = 0;
                var mixed = false;
                var tbl_sel: [3]u5 = .{ 0, 0, 0 };
                var sub_gain: [3]u3 = .{ 0, 0, 0 };
                var r0_cnt: u4 = 0;
                var r1_cnt: u3 = 0;

                if (win_switch) {
                    b_type = try sbr.readBits(u2, 2);
                    mixed = (try sbr.readBit() == 1);
                    tbl_sel[0] = try sbr.readBits(u5, 5);
                    tbl_sel[1] = try sbr.readBits(u5, 5);
                    sub_gain[0] = try sbr.readBits(u3, 3);
                    sub_gain[1] = try sbr.readBits(u3, 3);
                    sub_gain[2] = try sbr.readBits(u3, 3);
                } else {
                    tbl_sel[0] = try sbr.readBits(u5, 5);
                    tbl_sel[1] = try sbr.readBits(u5, 5);
                    tbl_sel[2] = try sbr.readBits(u5, 5);
                    r0_cnt = try sbr.readBits(u4, 4);
                    r1_cnt = try sbr.readBits(u3, 3);
                }

                const pre = if (is_mpeg1) try sbr.readBit() else 0;
                const scf_scale = try sbr.readBit();
                const count1_tbl = try sbr.readBit();

                gr_ch[gr][ch] = .{
                    .part2_3_length = part2_3_len,
                    .big_values = big_vals,
                    .global_gain = gain,
                    .scalefac_compress = scf_compress,
                    .window_switching_flag = win_switch,
                    .block_type = b_type,
                    .mixed_block_flag = mixed,
                    .table_select = tbl_sel,
                    .subblock_gain = sub_gain,
                    .region0_count = r0_cnt,
                    .region1_count = r1_cnt,
                    .preflag = pre,
                    .scalefac_scale = scf_scale,
                    .count1table_select = count1_tbl,
                };
            }
        }

        // 3. Bit Reservoir Assembly
        const main_payload_start = header_offset + side_info_len;
        const available_frame_bytes = @min(frame_len, in_payload.len);
        const main_data_len = if (available_frame_bytes > main_payload_start)
            available_frame_bytes - main_payload_start
        else
            0;

        // Shift and copy into reservoir
        if (self.reservoir_len + main_data_len > self.reservoir.len) {
            const keep = @min(self.reservoir_len, 2048);
            std.mem.copyForwards(u8, self.reservoir[0..keep], self.reservoir[self.reservoir_len - keep .. self.reservoir_len]);
            self.reservoir_len = keep;
        }

        if (main_data_len > 0) {
            @memcpy(self.reservoir[self.reservoir_len .. self.reservoir_len + main_data_len], in_payload[main_payload_start .. main_payload_start + main_data_len]);
            self.reservoir_len += main_data_len;
        }

        const reservoir_start = if (self.reservoir_len >= main_data_begin)
            self.reservoir_len - main_data_begin
        else
            0;

        var main_br = bit_reader.BitReader.init(self.reservoir[reservoir_start..self.reservoir_len]);

        // 4. Decode Granules
        var total_samples_written: usize = 0;
        var pcm_step_l: [32]f32 = undefined;
        var pcm_step_r: [32]f32 = undefined;

        for (0..n_granules) |gr| {
            var xr: [2][576]f32 = std.mem.zeroes([2][576]f32);

            for (0..n_channels) |ch| {
                const info = gr_ch[gr][ch];
                const sfb_long = &tables.SFB_MPEG1_LONG[srate_idx];

                // Decode scalefactors
                var scalefac: [39]u8 = std.mem.zeroes([39]u8);
                if (is_mpeg1 and info.scalefac_compress < 16) {
                    const slens = tables.SLEN_MPEG1[info.scalefac_compress];
                    for (0..11) |sfb| {
                        if (slens[0] > 0) scalefac[sfb] = try main_br.readBits(u8, slens[0]);
                    }
                    for (11..22) |sfb| {
                        if (slens[1] > 0) scalefac[sfb] = try main_br.readBits(u8, slens[1]);
                    }
                }

                // Decode Huffman frequency spectrum
                var idx: usize = 0;
                var pair_idx: usize = 0;
                const big_vals_limit = @min(@as(usize, info.big_values) * 2, 576);

                while (idx + 1 < big_vals_limit and main_br.bitsLeft() >= 2) : (pair_idx += 1) {
                    const table_sel = info.table_select[0];
                    const pair = huffman.decodeBigValuesPair(&main_br, table_sel) catch break;

                    // Dequantize |is|^(4/3) * 2^((gain - 210)/4)
                    const gain_scale = std.math.pow(f32, 2.0, (@as(f32, @floatFromInt(info.global_gain)) - 210.0) / 4.0);
                    const fx: f32 = @floatFromInt(pair.x);
                    const fy: f32 = @floatFromInt(pair.y);

                    const mag_x = std.math.pow(f32, @abs(fx), 4.0 / 3.0);
                    const mag_y = std.math.pow(f32, @abs(fy), 4.0 / 3.0);

                    xr[ch][idx] = (if (pair.x < 0) -mag_x else mag_x) * gain_scale * 0.05;
                    xr[ch][idx + 1] = (if (pair.y < 0) -mag_y else mag_y) * gain_scale * 0.05;
                    idx += 2;
                }

                // Decode count1 quads
                while (idx + 3 < 576 and main_br.bitsLeft() >= 4) {
                    const quad = huffman.decodeCount1Quad(&main_br, info.count1table_select) catch break;
                    if (quad.v == 0 and quad.w == 0 and quad.x == 0 and quad.y == 0) break;

                    xr[ch][idx] = @as(f32, @floatFromInt(quad.v)) * 0.01;
                    xr[ch][idx + 1] = @as(f32, @floatFromInt(quad.w)) * 0.01;
                    xr[ch][idx + 2] = @as(f32, @floatFromInt(quad.x)) * 0.01;
                    xr[ch][idx + 3] = @as(f32, @floatFromInt(quad.y)) * 0.01;
                    idx += 4;
                }

                // Alias reduction butterflies between adjacent subbands
                if (info.block_type != 2) {
                    for (0..31) |sb| {
                        for (0..8) |i| {
                            const idx1 = sb * 18 + 17 - i;
                            const idx2 = (sb + 1) * 18 + i;
                            const x1 = xr[ch][idx1];
                            const x2 = xr[ch][idx2];
                            xr[ch][idx1] = x1 * tables.ALIAS_CS[i] - x2 * tables.ALIAS_CA[i];
                            xr[ch][idx2] = x2 * tables.ALIAS_CS[i] + x1 * tables.ALIAS_CA[i];
                        }
                    }
                }
                _ = sfb_long;
            }

            // Mid/Side stereo processing if joint stereo
            if (self.channel_mode == .joint_stereo and (self.mode_extension & 0x02) != 0 and n_channels == 2) {
                const inv_sqrt2: f32 = 0.7071067811865475;
                for (0..576) |i| {
                    const m = xr[0][i];
                    const s = xr[1][i];
                    xr[0][i] = (m + s) * inv_sqrt2;
                    xr[1][i] = (m - s) * inv_sqrt2;
                }
            }

            // IMDCT and Polyphase Synthesis for each channel
            var subband_l: [18][32]f32 = undefined;
            var subband_r: [18][32]f32 = undefined;

            self.imdct.process(0, gr_ch[gr][0].block_type, gr_ch[gr][0].mixed_block_flag, &xr[0], &subband_l);
            if (n_channels == 2) {
                self.imdct.process(1, gr_ch[gr][1].block_type, gr_ch[gr][1].mixed_block_flag, &xr[1], &subband_r);
            }

            // Run synthesis filterbank for the 18 steps (18 * 32 = 576 PCM samples per channel)
            for (0..18) |step| {
                self.synth.synthesize32(0, &subband_l[step], &pcm_step_l);
                if (n_channels == 2) {
                    self.synth.synthesize32(1, &subband_r[step], &pcm_step_r);
                } else {
                    @memcpy(&pcm_step_r, &pcm_step_l);
                }

                // Interleave L and R into out_interleaved
                for (0..32) |s| {
                    if (total_samples_written * 2 + 1 < out_interleaved.len) {
                        out_interleaved[total_samples_written * 2] = std.math.clamp(pcm_step_l[s], -1.0, 1.0);
                        out_interleaved[total_samples_written * 2 + 1] = std.math.clamp(pcm_step_r[s], -1.0, 1.0);
                        total_samples_written += 1;
                    }
                }
            }
        }

        return total_samples_written;
    }
};

test "Mp3Decoder initialization and reset" {
    var dec = Mp3Decoder.init();
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    dec.reset();
}

test "Mp3Decoder decodeFrame valid MPEG-1 Layer III frame" {
    var dec = Mp3Decoder.init();
    var frame_bytes: [417]u8 = std.mem.zeroes([417]u8);
    // Standard 128kbps 44.1kHz Joint Stereo MPEG-1 Layer III header
    frame_bytes[0] = 0xFF;
    frame_bytes[1] = 0xFB;
    frame_bytes[2] = 0x90;
    frame_bytes[3] = 0x64;

    var out_pcm: [1152 * 2]f32 = undefined;
    const n_samples = try dec.decodeFrame(&frame_bytes, &out_pcm);
    try std.testing.expectEqual(@as(usize, 1152), n_samples);
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    try std.testing.expectEqual(@as(u16, 128), dec.bitrate_kbps);
}
