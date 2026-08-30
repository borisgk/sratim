const std = @import("std");
const tables = @import("tables.zig");
const huffman = @import("huffman.zig");
const mdct = @import("../mdct.zig");
const bit_reader = @import("../ac3/bit_reader.zig");

pub const BitReader = bit_reader.BitReader;

pub const IcsInfo = struct {
    window_sequence: u2 = 0,
    window_shape: u1 = 0,
    max_sfb: usize = 0,
    num_windows: usize = 1,
    num_window_groups: usize = 1,
    group_len: [8]usize = [_]usize{1} ** 8,
};

pub const TnsData = struct {
    present: bool = false,
    n_filt: [8]usize = [_]usize{0} ** 8,
    length: [8][4]usize = [_][4]usize{[_]usize{0} ** 4} ** 8,
    direction: [8][4]u1 = [_][4]u1{[_]u1{0} ** 4} ** 8,
    order: [8][4]usize = [_][4]usize{[_]usize{0} ** 4} ** 8,
    coef: [8][4][12]f32 = [_][4][12]f32{[_][12]f32{[_]f32{0.0} ** 12} ** 4} ** 8,
};

pub const AacDecoder = struct {
    sample_rate: u32 = 48000,
    channels: u32 = 6,

    // Overlap-add delay buffers for up to 6 channels:
    // 0: Left, 1: Right, 2: Center, 3: Ls, 4: Rs, 5: LFE
    delay: [6][1024]f32 = [_][1024]f32{[_]f32{0.0} ** 1024} ** 6,
    last_ch_pcm: [6][1024]f32 = [_][1024]f32{[_]f32{0.0} ** 1024} ** 6,
    prev_window_shape: [6]u1 = [_]u1{0} ** 6,
    seed: u32 = 0x31415926,
    lcg_state: u32 = 0x38181449,
    frame_count: usize = 0,
    trace_first_error: bool = true, // enable bit-trace for the first failing frame

    pub fn init() AacDecoder {
        return .{};
    }

    pub fn reset(self: *AacDecoder) void {
        for (&self.delay) |*ch_delay| @memset(ch_delay, 0.0);
        @memset(&self.prev_window_shape, 0);
    }

    /// Decodes a single AAC-LC raw data block (or ADTS frame) into 1024 stereo interleaved float PCM samples.
    /// out_stereo_pcm must have capacity for at least 2048 f32 samples.
    /// Returns 1024 on success.
    pub fn decodeFrame(self: *AacDecoder, bytes: []const u8, out_stereo_pcm: []f32) !usize {
        if (bytes.len == 0) return error.InputBufferTooSmall;
        if (out_stereo_pcm.len < 2048) return error.OutputBufferTooSmall;

        self.frame_count += 1;

        var raw_bytes = bytes;
        // Check if prefixed by ADTS syncword (0xFFF)
        if (raw_bytes.len >= 7 and raw_bytes[0] == 0xFF and (raw_bytes[1] & 0xF0) == 0xF0) {
            const protection_absent = raw_bytes[1] & 1;
            const header_size: usize = if (protection_absent == 1) 7 else 9;
            if (raw_bytes.len < header_size) return error.InputBufferTooSmall;
            const frame_len = (@as(usize, raw_bytes[3] & 0x03) << 11) | (@as(usize, raw_bytes[4]) << 3) | (@as(usize, raw_bytes[5] >> 5));
            const actual_len = @min(frame_len, raw_bytes.len);
            raw_bytes = raw_bytes[header_size..actual_len];
        }

        var reader = BitReader.init(raw_bytes);



        // Buffers for 6 channels (1024 time samples each)
        // 0: Left, 1: Right, 2: Center, 3: Ls, 4: Rs, 5: LFE
        var ch_pcm: [6][1024]f32 = [_][1024]f32{[_]f32{0.0} ** 1024} ** 6;
        var has_ch: [6]bool = [_]bool{false} ** 6;

        var sce_count: usize = 0;
        var cpe_count: usize = 0;




        while (reader.bitsLeft() >= 3) {
            const elem_type = reader.readBits(u3, 3) catch |err| {
                if (err == error.EndOfBitstream and (has_ch[0] or has_ch[2])) break;
                return err;
            };

            if (elem_type == 7) {
                break; // ID_END terminates raw_data_block
            }

            const tag: u4 = if (elem_type != 6) reader.readBits(u4, 4) catch |err| {
                if (err == error.EndOfBitstream and (has_ch[0] or has_ch[2])) break;
                return err;
            } else 0;
            _ = tag;
            switch (elem_type) {
                0 => { // ID_SCE (Single Channel Element)
                    const ch_idx: usize = if (self.channels >= 6) (if (sce_count == 0) 2 else 3) else 0;
                    self.decodeChannel(&reader, &ch_pcm[ch_idx], ch_idx) catch |err| {
                        if (err == error.EndOfBitstream and (has_ch[0] or has_ch[2])) break;
                        return err;
                    };
                    has_ch[ch_idx] = true;
                    sce_count += 1;
                },
                1 => { // ID_CPE (Channel Pair Element)
                    const ch_l: usize = if (cpe_count == 0) 0 else 4;
                    const ch_r: usize = if (cpe_count == 0) 1 else 5;
                    self.decodeCpe(&reader, &ch_pcm[ch_l], &ch_pcm[ch_r], ch_l, ch_r) catch |err| {
                        if (err == error.EndOfBitstream and (has_ch[0] or has_ch[2])) break;
                        return err;
                    };
                    has_ch[ch_l] = true;
                    has_ch[ch_r] = true;
                    cpe_count += 1;
                },
                2 => { // ID_CCE (Coupling Channel Element - ISO/IEC 14496-3 Table 4.8)
                    _ = try reader.readBits(u2, 2); // element_instance_tag
                    const ind_sw_cpe = try reader.readBit();
                    const num_coupled_elements = try reader.readBits(usize, 3);
                    var num_gain_element_lists: usize = 0;
                    for (0..num_coupled_elements + 1) |_| {
                        num_gain_element_lists += 1;
                        _ = try reader.readBit(); // cc_target_is_cpe
                        _ = try reader.readBits(u4, 4); // cc_target_tag_select
                        if (ind_sw_cpe == 1) {
                            _ = try reader.readBit(); // cc_l
                            _ = try reader.readBit(); // cc_r
                            num_gain_element_lists += 1;
                        }
                    }
                    _ = try reader.readBits(u2, 2); // cc_domain
                    _ = try reader.readBit(); // cc_edge
                    const count = try reader.readBits(usize, 4); // cce scale factor count
                    for (0..count) |_| {
                        _ = try reader.readBits(u8, 8);
                    }
                },
                3 => { // ID_LFE (Low Frequency Enhancement Element - ISO/IEC 14496-3 Table 4.9)
                    const ch_lfe: usize = 3;
                    self.decodeChannel(&reader, &ch_pcm[ch_lfe], ch_lfe) catch |err| {
                        if (err == error.EndOfBitstream and (has_ch[0] or has_ch[2])) break;
                        return err;
                    };
                    has_ch[ch_lfe] = true;
                },
                4 => { // ID_DSE (Data Stream Element - ISO/IEC 14496-3 Table 4.10)
                    const data_byte_align_flag = try reader.readBit();
                    var count = try reader.readBits(usize, 8);
                    if (count == 255) count += try reader.readBits(usize, 8);
                    if (data_byte_align_flag == 1) {
                        reader.byteAlign();
                    }
                    try reader.skipBits(count * 8);
                },
                5 => { // ID_PCE (Program Config Element - ISO/IEC 14496-3 Table 4.2)
                    _ = try reader.readBits(u2, 2); // object_type
                    _ = try reader.readBits(u4, 4); // sampling_frequency_index
                    const num_front = try reader.readBits(usize, 4);
                    const num_side = try reader.readBits(usize, 4);
                    const num_back = try reader.readBits(usize, 4);
                    const num_lfe = try reader.readBits(usize, 2);
                    const num_assoc = try reader.readBits(usize, 3);
                    const num_cc = try reader.readBits(usize, 4);

                    if ((try reader.readBit()) == 1) _ = try reader.readBits(u4, 4); // mono_mixdown
                    if ((try reader.readBit()) == 1) _ = try reader.readBits(u4, 4); // stereo_mixdown
                    if ((try reader.readBit()) == 1) { // matrix_mixdown
                        _ = try reader.readBits(u2, 2);
                        _ = try reader.readBit();
                    }

                    for (0..num_front) |_| {
                        _ = try reader.readBit(); // is_cpe
                        _ = try reader.readBits(u4, 4); // tag
                    }
                    for (0..num_side) |_| {
                        _ = try reader.readBit();
                        _ = try reader.readBits(u4, 4);
                    }
                    for (0..num_back) |_| {
                        _ = try reader.readBit();
                        _ = try reader.readBits(u4, 4);
                    }
                    for (0..num_lfe) |_| {
                        _ = try reader.readBits(u4, 4);
                    }
                    for (0..num_assoc) |_| {
                        _ = try reader.readBits(u4, 4);
                    }
                    for (0..num_cc) |_| {
                        _ = try reader.readBit(); // is_ind_sw
                        _ = try reader.readBits(u4, 4);
                    }
                    reader.byteAlign();
                    const comment_len = try reader.readBits(usize, 8);
                    try reader.skipBits(comment_len * 8);
                },
                6 => { // ID_FIL (Fill Element - ISO/IEC 14496-3 Table 4.11)
                    var count = try reader.readBits(usize, 4);
                    if (count == 15) {
                        const ext = try reader.readBits(usize, 8);
                        if (ext > 0) {
                            count += ext - 1;
                        } else {
                            count = 14;
                        }
                    }
                    try reader.skipBits(count * 8);
                },
                else => {
                    break;
                },
            }
        }

        // Downmixing / Mapping into Stereo Interleaved Float PCM (normalized to [-1.0, 1.0])
        const INV_PCM_SCALE: f32 = 1.0 / 65536.0;
        self.last_ch_pcm = ch_pcm;

        if (self.channels >= 6 and (has_ch[0] or has_ch[2])) {
            // 5.1 Surround Downmixing to Stereo (ITU-R BS.775 / FFmpeg SWR normalization):
            // L_out = (L + C * 0.7071 + Ls * 0.7071) / (1 + sqrt(2))
            // R_out = (R + C * 0.7071 + Rs * 0.7071) / (1 + sqrt(2))
            const NORM_51: f32 = 1.0 / (1.0 + 2.0 * tables.LEVEL_3DB);
            const scale = INV_PCM_SCALE * NORM_51;
            for (0..1024) |s| {
                const l = ch_pcm[0][s];
                const r = ch_pcm[1][s];
                const c = ch_pcm[2][s];
                const ls = ch_pcm[4][s];
                const rs = ch_pcm[5][s];
                out_stereo_pcm[s * 2 + 0] = (l + c * tables.LEVEL_3DB + ls * tables.LEVEL_3DB) * scale;
                out_stereo_pcm[s * 2 + 1] = (r + c * tables.LEVEL_3DB + rs * tables.LEVEL_3DB) * scale;
            }
        } else if (has_ch[0] and has_ch[1]) {
            // Stereo
            for (0..1024) |s| {
                out_stereo_pcm[s * 2 + 0] = ch_pcm[0][s] * INV_PCM_SCALE;
                out_stereo_pcm[s * 2 + 1] = ch_pcm[1][s] * INV_PCM_SCALE;
            }
        } else if (has_ch[0]) {
            // Mono
            for (0..1024) |s| {
                out_stereo_pcm[s * 2 + 0] = ch_pcm[0][s] * INV_PCM_SCALE;
                out_stereo_pcm[s * 2 + 1] = ch_pcm[0][s] * INV_PCM_SCALE;
            }
        } else {
            // Zero fill
            @memset(out_stereo_pcm[0..2048], 0.0);
        }

        return 1024;
    }

    fn decodeIcsInfo(reader: *BitReader, ics: *IcsInfo) !void {
        _ = try reader.readBit(); // ics_reserved_bit
        ics.window_sequence = try reader.readBits(u2, 2);
        ics.window_shape = try reader.readBit();

        if (ics.window_sequence == 2) { // EIGHT_SHORT_SEQUENCE
            ics.max_sfb = try reader.readBits(usize, 4);
            const grouping = try reader.readBits(u7, 7);
            ics.num_windows = 8;
            ics.num_window_groups = 1;
            ics.group_len[0] = 1;
            for (0..7) |i| {
                const bit = (grouping >> @intCast(6 - i)) & 1;
                if (bit == 1) {
                    ics.group_len[ics.num_window_groups - 1] += 1;
                } else {
                    ics.num_window_groups += 1;
                    ics.group_len[ics.num_window_groups - 1] = 1;
                }
            }
        } else {
            ics.max_sfb = try reader.readBits(usize, 6);
            const predictor_data_present = (try reader.readBit()) == 1;
            if (predictor_data_present) {
                return error.PredictorNotSupportedInAacLc;
            }
            ics.num_windows = 1;
            ics.num_window_groups = 1;
            ics.group_len[0] = 1;
        }
    }

    fn decodeChannel(self: *AacDecoder, reader: *BitReader, out_pcm: *[1024]f32, ch_idx: usize) !void {
        var ics = IcsInfo{};
        const global_gain = try reader.readBits(u8, 8);
        try decodeIcsInfo(reader, &ics);

        var spectrum: [1024]f32 = [_]f32{0.0} ** 1024;
        var tns = TnsData{};
        try self.decodeIcsPayload(reader, &ics, global_gain, &spectrum, &tns, null, null);
        applyTns(&spectrum, &ics, &tns);

        self.applyImdctAndWindow(&ics, &spectrum, out_pcm, ch_idx);
    }

    fn decodeCpe(
        self: *AacDecoder,
        reader: *BitReader,
        out_l: *[1024]f32,
        out_r: *[1024]f32,
        ch_l: usize,
        ch_r: usize,
    ) !void {
        const common_window = (try reader.readBit()) == 1;
        var ics_l = IcsInfo{};
        var ics_r = IcsInfo{};

        var ms_mask: [8][64]bool = [_][64]bool{[_]bool{false} ** 64} ** 8;

        if (common_window) {
            try decodeIcsInfo(reader, &ics_l);
            ics_r = ics_l;

            const ms_mask_present = try reader.readBits(u2, 2);
            if (ms_mask_present == 1) {
                for (0..ics_l.num_window_groups) |g| {
                    for (0..ics_l.max_sfb) |sfb| {
                        ms_mask[g][sfb] = (try reader.readBit()) == 1;
                    }
                }
            } else if (ms_mask_present == 2) {
                for (0..ics_l.num_window_groups) |g| {
                    for (0..ics_l.max_sfb) |sfb| {
                        ms_mask[g][sfb] = true;
                    }
                }
            }
        }

        const global_gain_l = try reader.readBits(u8, 8);
        if (!common_window) {
            try decodeIcsInfo(reader, &ics_l);
        }
        var spec_l: [1024]f32 = [_]f32{0.0} ** 1024;
        var tns_l = TnsData{};
        try self.decodeIcsPayload(reader, &ics_l, global_gain_l, &spec_l, &tns_l, null, null);

        const global_gain_r = try reader.readBits(u8, 8);
        if (!common_window) {
            try decodeIcsInfo(reader, &ics_r);
        }
        var spec_r: [1024]f32 = [_]f32{0.0} ** 1024;
        var tns_r = TnsData{};
        var sfb_cb_r: [8][64]u4 = undefined;
        var sfb_sf_r: [8][64]i32 = undefined;
        try self.decodeIcsPayload(reader, &ics_r, global_gain_r, &spec_r, &tns_r, &sfb_cb_r, &sfb_sf_r);

        // Apply Mid/Side (M/S) stereo and Intensity Stereo if common window
        if (common_window) {
            const swb_offset = if (ics_l.window_sequence == 2) &tables.SWB_OFFSET_SHORT_48000 else &tables.SWB_OFFSET_48000;
            const win_len: usize = 1024 / ics_l.num_windows;
            var g_win_start: usize = 0;
            for (0..ics_l.num_window_groups) |g| {
                for (0..ics_l.max_sfb) |sfb| {
                    if (sfb + 1 >= swb_offset.len) continue;
                    const cb_r = sfb_cb_r[g][sfb];
                    const invert: f32 = if (cb_r == 14) -1.0 else 1.0;
                    const ms_invert: f32 = if (ms_mask[g][sfb]) -1.0 else 1.0;
                    const is_scale = @exp2(-@as(f32, @floatFromInt(sfb_sf_r[g][sfb])) * 0.25) * invert * ms_invert;

                    for (0..ics_l.group_len[g]) |w| {
                        const w_idx = g_win_start + w;
                        const w_base = w_idx * win_len;
                        const start = w_base + swb_offset[sfb];
                        const end = w_base + swb_offset[sfb + 1];

                        if (cb_r == 14 or cb_r == 15) {
                            // Intensity Stereo
                            for (start..end) |k| {
                                spec_r[k] = spec_l[k] * is_scale;
                            }
                        } else if (ms_mask[g][sfb]) {
                            // Mid/Side (M/S) stereo
                            for (start..end) |k| {
                                const m = spec_l[k];
                                const s = spec_r[k];
                                spec_l[k] = m + s;
                                spec_r[k] = m - s;
                            }
                        }
                    }
                }
                g_win_start += ics_l.group_len[g];
            }
        }

        applyTns(&spec_l, &ics_l, &tns_l);
        applyTns(&spec_r, &ics_r, &tns_r);

        self.applyImdctAndWindow(&ics_l, &spec_l, out_l, ch_l);
        self.applyImdctAndWindow(&ics_r, &spec_r, out_r, ch_r);
    }

    fn decodeIcsPayload(
        self: *AacDecoder,
        reader: *BitReader,
        ics: *IcsInfo,
        global_gain: u8,
        spectrum: *[1024]f32,
        out_tns: ?*TnsData,
        out_cb: ?*[8][64]u4,
        out_sf: ?*[8][64]i32,
    ) !void {
        _ = self;
        var sfb_cb: [8][64]u4 = [_][64]u4{[_]u4{0} ** 64} ** 8;
        var sfb_sf: [8][64]i32 = [_][64]i32{[_]i32{0} ** 64} ** 8;

        const bits_len: usize = if (ics.window_sequence == 2) 3 else 5;
        const max_incr: usize = (@as(usize, 1) << @as(u5, @intCast(bits_len))) - 1;

        // 1. Section data
        for (0..ics.num_window_groups) |g| {
            var k: usize = 0;
            while (k < ics.max_sfb) {
                const sect_cb = try reader.readBits(u4, 4);
                var sect_len: usize = 0;
                while (true) {
                    const incr = try reader.readBits(usize, bits_len);
                    sect_len += incr;
                    if (incr != max_incr) break;
                }
                const end_k = @min(ics.max_sfb, k + sect_len);
                while (k < end_k) : (k += 1) {
                    sfb_cb[g][k] = sect_cb;
                }
            }
        }

        // 2. Scale factor data (ISO/IEC 14496-3 Section 4.5.2.3.2)
        var sf: i32 = global_gain;
        var is_pos: i32 = 0;
        var noise_nrg: i32 = @as(i32, global_gain) - 90;
        var noise_pcm_flag: bool = true;

        for (0..ics.num_window_groups) |g| {
            for (0..ics.max_sfb) |sfb| {
                const cb = sfb_cb[g][sfb];
                if (cb == 0) {
                    sfb_sf[g][sfb] = 0;
                } else if (cb == 14 or cb == 15) {
                    // Intensity stereo position
                    const sym = try huffman.decodeSymbol(reader, &huffman.SF_TRIE);
                    is_pos += @as(i32, @intCast(sym)) - 60;
                    sfb_sf[g][sfb] = is_pos;
                } else if (cb == 13) {
                    // PNS noise energy
                    if (noise_pcm_flag) {
                        noise_pcm_flag = false;
                        const pcm_bits = try reader.readBits(usize, 9);
                        noise_nrg = (@as(i32, global_gain) - 90 - 256) + @as(i32, @intCast(pcm_bits));
                    } else {
                        const sym = try huffman.decodeSymbol(reader, &huffman.SF_TRIE);
                        noise_nrg += @as(i32, @intCast(sym)) - 60;
                    }
                    sfb_sf[g][sfb] = noise_nrg;
                } else {
                    // Normal scale factor (cb 1..11)
                    const sym = try huffman.decodeSymbol(reader, &huffman.SF_TRIE);
                    sf += @as(i32, @intCast(sym)) - 60;
                    sfb_sf[g][sfb] = sf;
                }
            }
        }

        if (out_cb) |c| c.* = sfb_cb;
        if (out_sf) |s| s.* = sfb_sf;

        // 3. Pulse data (ISO/IEC 14496-3 Table 4.50)
        const pulse_present = (try reader.readBit()) == 1;
        if (pulse_present) {
            if (ics.window_sequence == 2) {
                return error.PulseNotAllowedInEightShortSequence;
            }
            const number_pulse = try reader.readBits(usize, 2);
            _ = try reader.readBits(usize, 6); // pulse_start_sfb
            for (0..number_pulse + 1) |_| {
                _ = try reader.readBits(u5, 5); // pulse_offset
                _ = try reader.readBits(u4, 4); // pulse_amp
            }
        }

        var dummy_tns = TnsData{};
        const tns_target = out_tns orelse &dummy_tns;
        try parseTnsData(reader, ics, tns_target);

        // 5. Gain control data present flag (1 bit in individual_channel_stream; SSR only, ignored in AAC-LC)
        _ = try reader.readBit();

        // 6. Spectral data decoding & Dequantization (ISO/IEC 14496-3 Table 4.56)
        const swb_offset = if (ics.window_sequence == 2) &tables.SWB_OFFSET_SHORT_48000 else &tables.SWB_OFFSET_48000;
        const win_len: usize = 1024 / ics.num_windows;
        var g_win_start: usize = 0;
        var q_buf: [1024]i32 = [_]i32{0} ** 1024;

        for (0..ics.num_window_groups) |g| {
            for (0..ics.max_sfb) |sfb| {
                if (sfb + 1 >= swb_offset.len) break;
                const cb = sfb_cb[g][sfb];
                const start = swb_offset[sfb];
                const end = swb_offset[sfb + 1];
                const len = end - start;

                for (0..ics.group_len[g]) |w| {
                    const w_idx = g_win_start + w;
                    const w_base = w_idx * win_len;

                    if (cb > 0 and cb <= 11) {
                        _ = try huffman.decodeSpectralBins(reader, cb, q_buf[0..len]);
                        const cur_sf = sfb_sf[g][sfb];
                        const sf_scale = @exp2(@as(f32, @floatFromInt(cur_sf - 100)) * 0.25);

                        for (0..len) |i| {
                            const val = q_buf[i];
                            if (val == 0) {
                                spectrum[w_base + start + i] = 0.0;
                            } else {
                                const abs_v: usize = @intCast(if (val < 0) -val else val);
                                const v43 = if (abs_v < tables.POW43.len) tables.POW43[abs_v] else std.math.pow(f32, @as(f32, @floatFromInt(abs_v)), 4.0 / 3.0);
                                const signed_v = if (val < 0) -v43 else v43;
                                const out_val = signed_v * sf_scale;

                                spectrum[w_base + start + i] = out_val;
                            }
                        }
                    } else if (cb == 13) {
                        // Perceptual Noise Substitution (PNS) - zeroed to prevent amplitude distortion
                        @memset(spectrum[w_base + start .. w_base + end], 0.0);
                    } else {
                        @memset(spectrum[w_base + start .. w_base + end], 0.0);
                    }
                }
            }
            g_win_start += ics.group_len[g];
        }
    }

    fn computeLpcCoefs(autoc: []const f32, order: usize, lpc: []f32) void {
        for (0..order) |i| {
            const r = -autoc[i];
            lpc[i] = r;
            const half = (i + 1) >> 1;
            for (0..half) |j| {
                const f = lpc[j];
                const b = lpc[i - 1 - j];
                lpc[j] = f + r * b;
                lpc[i - 1 - j] = b + r * f;
            }
        }
    }

    fn applyTns(spectrum: *[1024]f32, ics: *const IcsInfo, tns: *const TnsData) void {
        if (!tns.present) return;

        const is8 = (ics.window_sequence == 2);
        const tns_max_bands: usize = if (is8) tables.TNS_MAX_BANDS_128[3] else tables.TNS_MAX_BANDS_1024[3];
        const mmm = @min(tns_max_bands, ics.max_sfb);
        if (mmm == 0) return;

        const num_swb: usize = if (is8) tables.NUM_SHORT_SFBS_48000 else tables.NUM_SFBS_48000;
        const swb_offset = if (is8) &tables.SWB_OFFSET_SHORT_48000 else &tables.SWB_OFFSET_48000;

        for (0..ics.num_windows) |w| {
            var bottom: usize = num_swb;
            for (0..tns.n_filt[w]) |filt| {
                const top = bottom;
                bottom = if (top > tns.length[w][filt]) top - tns.length[w][filt] else 0;
                const order = tns.order[w][filt];
                if (order == 0) continue;

                var lpc: [12]f32 = undefined;
                computeLpcCoefs(tns.coef[w][filt][0..order], order, lpc[0..order]);

                const b_idx = @min(bottom, mmm);
                const t_idx = @min(top, mmm);
                const start_sfb = swb_offset[b_idx];
                const end_sfb = swb_offset[t_idx];
                if (end_sfb <= start_sfb) continue;
                const size = end_sfb - start_sfb;

                const dir = tns.direction[w][filt];
                const w_offset = w * 128;

                if (dir == 0) {
                    // Increasing frequency
                    const base = w_offset + start_sfb;
                    for (0..size) |m| {
                        const idx = base + m;
                        const max_i = @min(m, order);
                        for (1..max_i + 1) |i| {
                            spectrum[idx] -= spectrum[idx - i] * lpc[i - 1];
                        }
                    }
                } else {
                    // Decreasing frequency
                    const base = w_offset + end_sfb - 1;
                    for (0..size) |m| {
                        const idx = base - m;
                        const max_i = @min(m, order);
                        for (1..max_i + 1) |i| {
                            spectrum[idx] -= spectrum[idx + i] * lpc[i - 1];
                        }
                    }
                }
            }
        }
    }

    fn parseTnsData(reader: *BitReader, ics: *const IcsInfo, tns: *TnsData) !void {
        tns.present = (try reader.readBit()) == 1;
        if (!tns.present) return;

        const is8 = (ics.window_sequence == 2);
        const tns_max_order: usize = if (is8) 7 else 12;

        for (0..ics.num_windows) |w| {
            const n_filt = try reader.readBits(usize, if (is8) 1 else 2);
            tns.n_filt[w] = n_filt;
            if (n_filt > 0) {
                const coef_res = try reader.readBit();
                for (0..n_filt) |filt| {
                    tns.length[w][filt] = try reader.readBits(usize, if (is8) 4 else 6);
                    const order = try reader.readBits(usize, if (is8) 3 else 5);
                    if (order > tns_max_order) {
                        tns.order[w][filt] = 0;
                        return error.TnsOrderTooHigh;
                    }
                    tns.order[w][filt] = order;
                    if (order > 0) {
                        tns.direction[w][filt] = try reader.readBits(u1, 1);
                        const coef_compress = try reader.readBit();
                        const coef_len: u5 = @as(u5, coef_res) + 3 - @as(u5, coef_compress);
                        const tmp2_idx = 2 * @as(usize, coef_compress) + @as(usize, coef_res);

                        for (0..order) |i| {
                            const coef_idx = try reader.readBits(usize, coef_len);
                            tns.coef[w][filt][i] = switch (tmp2_idx) {
                                0 => tables.TNS_TMP2_MAP_0_3[coef_idx],
                                1 => tables.TNS_TMP2_MAP_0_4[coef_idx],
                                2 => tables.TNS_TMP2_MAP_1_3[coef_idx],
                                3 => tables.TNS_TMP2_MAP_1_4[coef_idx],
                                else => 0.0,
                            };
                        }
                    }
                }
            }
        }
    }

    /// Synthesis windowing and IMDCT per ISO/IEC 14496-3 Subclause 4.5.2.8.2.
    fn applyImdctAndWindow(
        self: *AacDecoder,
        ics: *IcsInfo,
        spectrum: *const [1024]f32,
        out_pcm: *[1024]f32,
        ch: usize,
    ) void {
        const win_prev_long = if (self.prev_window_shape[ch] == 1) &tables.KBD_WINDOW_2048 else &tables.SINE_WINDOW_2048;
        const win_curr_long = if (ics.window_shape == 1) &tables.KBD_WINDOW_2048 else &tables.SINE_WINDOW_2048;
        const win_prev_short = if (self.prev_window_shape[ch] == 1) &tables.KBD_WINDOW_256 else &tables.SINE_WINDOW_256;
        const win_curr_short = if (ics.window_shape == 1) &tables.KBD_WINDOW_256 else &tables.SINE_WINDOW_256;

        if (self.frame_count == 1) {
            var max_s: f32 = 0;
            var max_idx: usize = 0;
            for (spectrum, 0..) |v, idx| {
                if (@abs(v) > max_s) {
                    max_s = @abs(v);
                    max_idx = idx;
                }
            }
            std.debug.print("  [F0 IMDCT ch={d}] max_spec={d:.4} at bin={d} win_seq={d}\n", .{ ch, max_s, max_idx, ics.window_sequence });
        }

        switch (ics.window_sequence) {
            0 => { // ONLY_LONG_SEQUENCE
                var time_2048: [2048]f32 = undefined;
                mdct.MdctEngine.imdct(1024, spectrum, &time_2048);

                for (0..1024) |i| time_2048[i] *= win_prev_long[i];
                for (1024..2048) |i| time_2048[i] *= win_curr_long[i];

                for (0..1024) |i| {
                    out_pcm[i] = self.delay[ch][i] + time_2048[i];
                    self.delay[ch][i] = time_2048[1024 + i];
                }
            },
            1 => { // LONG_START_SEQUENCE
                var time_2048: [2048]f32 = undefined;
                mdct.MdctEngine.imdct(1024, spectrum, &time_2048);

                // Left half (0..1024): long window
                for (0..1024) |i| time_2048[i] *= win_prev_long[i];
                // Right half (1024..2048): 448 ones, 128 short window (falling half), 448 zeros
                // 1024..1472: multiply by 1.0 (no-op)
                for (1472..1600) |i| time_2048[i] *= win_curr_short[128 + (i - 1472)];
                for (1600..2048) |i| time_2048[i] = 0.0;

                for (0..1024) |i| {
                    out_pcm[i] = self.delay[ch][i] + time_2048[i];
                    self.delay[ch][i] = time_2048[1024 + i];
                }
            },
            2 => { // EIGHT_SHORT_SEQUENCE
                var short_buf: [2048]f32 = [_]f32{0.0} ** 2048;

                for (0..8) |w| {
                    var time_256: [256]f32 = undefined;
                    mdct.MdctEngine.imdct(128, spectrum[w * 128 .. (w + 1) * 128], &time_256);
                    const win_left = if (w == 0) win_prev_short else win_curr_short;
                    for (0..128) |i| time_256[i] *= win_left[i];
                    for (128..256) |i| time_256[i] *= win_curr_short[i];

                    const offset = 448 + w * 128;
                    for (0..256) |i| short_buf[offset + i] += time_256[i];
                }

                for (0..1024) |i| {
                    out_pcm[i] = self.delay[ch][i] + short_buf[i];
                    self.delay[ch][i] = short_buf[1024 + i];
                }
            },
            3 => { // LONG_STOP_SEQUENCE
                var time_2048: [2048]f32 = undefined;
                mdct.MdctEngine.imdct(1024, spectrum, &time_2048);

                // Left half (0..1024): 448 zeros, 128 short window (rising half), 448 ones
                for (0..448) |i| time_2048[i] = 0.0;
                for (448..576) |i| time_2048[i] *= win_prev_short[i - 448];
                // 576..1024: multiply by 1.0 (no-op)
                // Right half (1024..2048): long window
                for (1024..2048) |i| time_2048[i] *= win_curr_long[i];

                for (0..1024) |i| {
                    out_pcm[i] = self.delay[ch][i] + time_2048[i];
                    self.delay[ch][i] = time_2048[1024 + i];
                }
            },
        }
        self.prev_window_shape[ch] = ics.window_shape;
    }
};
