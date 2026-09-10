const std = @import("std");
pub const tables = @import("tables.zig");
pub const header = @import("header.zig");
pub const side_info = @import("side_info.zig");
pub const huffman = @import("huffman.zig");
pub const synthesis = @import("synthesis.zig");

// Re-export constants & functions for 100% backwards compatibility
pub const HDR_SIZE = header.HDR_SIZE;
pub const MAX_BITRESERVOIR_BYTES = side_info.MAX_BITRESERVOIR_BYTES;
pub const SHORT_BLOCK_TYPE = header.SHORT_BLOCK_TYPE;
pub const STOP_BLOCK_TYPE = header.STOP_BLOCK_TYPE;
pub const MODE_MONO = header.MODE_MONO;
pub const MODE_JOINT_STEREO = header.MODE_JOINT_STEREO;
pub const MAX_FREE_FORMAT_FRAME_SIZE = header.MAX_FREE_FORMAT_FRAME_SIZE;

pub const hdr_is_mono = header.hdr_is_mono;
pub const hdr_is_ms_stereo = header.hdr_is_ms_stereo;
pub const hdr_is_free_format = header.hdr_is_free_format;
pub const hdr_is_crc = header.hdr_is_crc;
pub const hdr_test_padding = header.hdr_test_padding;
pub const hdr_test_mpeg1 = header.hdr_test_mpeg1;
pub const hdr_test_not_mpeg25 = header.hdr_test_not_mpeg25;
pub const hdr_test_i_stereo = header.hdr_test_i_stereo;
pub const hdr_test_ms_stereo = header.hdr_test_ms_stereo;
pub const hdr_get_stereo_mode = header.hdr_get_stereo_mode;
pub const hdr_get_stereo_mode_ext = header.hdr_get_stereo_mode_ext;
pub const hdr_get_layer = header.hdr_get_layer;
pub const hdr_get_bitrate = header.hdr_get_bitrate;
pub const hdr_get_sample_rate = header.hdr_get_sample_rate;
pub const hdr_get_my_sample_rate = header.hdr_get_my_sample_rate;
pub const hdr_is_frame_576 = header.hdr_is_frame_576;
pub const hdr_is_layer_1 = header.hdr_is_layer_1;
pub const hdr_valid = header.hdr_valid;
pub const hdr_compare = header.hdr_compare;
pub const hdr_bitrate_kbps = header.hdr_bitrate_kbps;
pub const hdr_sample_rate_hz = header.hdr_sample_rate_hz;
pub const hdr_frame_samples = header.hdr_frame_samples;
pub const hdr_frame_bytes = header.hdr_frame_bytes;
pub const hdr_padding = header.hdr_padding;
pub const matchFrame = header.matchFrame;
pub const findFrame = header.findFrame;

pub const BitStream = side_info.BitStream;
pub const L3GrInfo = side_info.L3GrInfo;
pub const readSideInfo = side_info.readSideInfo;
pub const ldexpQ2 = side_info.ldexpQ2;
pub const readScalefactors = side_info.readScalefactors;
pub const decodeScalefactors = side_info.decodeScalefactors;
pub const restoreReservoir = side_info.restoreReservoir;
pub const saveReservoir = side_info.saveReservoir;

pub const pow43 = huffman.pow43;
pub const HuffmanBitReader = huffman.HuffmanBitReader;
pub const decodeHuffman = huffman.decodeHuffman;

pub const midsideStereo = synthesis.midsideStereo;
pub const intensityStereoBand = synthesis.intensityStereoBand;
pub const stereoTopBand = synthesis.stereoTopBand;
pub const stereoProcess = synthesis.stereoProcess;
pub const intensityStereo = synthesis.intensityStereo;
pub const reorder = synthesis.reorder;
pub const antialias = synthesis.antialias;
pub const dct3_9 = synthesis.dct3_9;
pub const imdct36 = synthesis.imdct36;
pub const idct3 = synthesis.idct3;
pub const imdct12 = synthesis.imdct12;
pub const imdctShort = synthesis.imdctShort;
pub const changeSign = synthesis.changeSign;
pub const imdctGranule = synthesis.imdctGranule;
pub const dctII = synthesis.dctII;
pub const scalePcm = synthesis.scalePcm;
pub const synthPair = synthesis.synthPair;
pub const synth = synthesis.synth;
pub const synthGranule = synthesis.synthGranule;

pub const Mp3Decoder = struct {
    sample_rate: u32 = 44100,
    channels: u16 = 2,
    bitrate_kbps: u16 = 128,

    mdct_overlap: [2][9 * 32]f32 = std.mem.zeroes([2][9 * 32]f32),
    qmf_state: [15 * 2 * 32]f32 = std.mem.zeroes([15 * 2 * 32]f32),
    reserv: usize = 0,
    free_format_bytes: usize = 0,
    header: [4]u8 = [_]u8{0} ** 4,
    reserv_buf: [511]u8 = [_]u8{0} ** 511,

    pub fn init() Mp3Decoder {
        return .{};
    }

    pub fn reset(self: *Mp3Decoder) void {
        self.* = .{};
    }

    pub fn decodeFrame(
        self: *Mp3Decoder,
        in_payload: []const u8,
        out_interleaved: []f32,
    ) !usize {
        if (in_payload.len == 0) return error.BufferTooSmall;
        if (out_interleaved.len < 1152 * 2) return error.BufferTooSmall;

        var frame_size: usize = 0;
        var offset: usize = 0;

        if (in_payload.len > 4 and self.header[0] == 0xFF and hdr_compare(&self.header, in_payload)) {
            frame_size = hdr_frame_bytes(in_payload, self.free_format_bytes) + hdr_padding(in_payload);
            if (frame_size != in_payload.len and (frame_size + HDR_SIZE > in_payload.len or !hdr_compare(in_payload, in_payload[frame_size..]))) {
                frame_size = 0;
            }
        }

        if (frame_size == 0) {
            self.reset();
            offset = findFrame(in_payload, &self.free_format_bytes, &frame_size);
            if (frame_size == 0 or offset + frame_size > in_payload.len) {
                return error.InvalidData;
            }
        }

        const hdr = in_payload[offset .. offset + HDR_SIZE];
        @memcpy(&self.header, hdr);
        const nch: usize = if (hdr_is_mono(hdr)) 1 else 2;
        self.channels = @intCast(nch);
        self.sample_rate = hdr_sample_rate_hz(hdr);
        self.bitrate_kbps = @intCast(hdr_bitrate_kbps(hdr));

        var bs_frame = BitStream.init(in_payload[offset + HDR_SIZE .. offset + frame_size]);
        if (hdr_is_crc(hdr)) {
            _ = bs_frame.getBits(16);
        }

        var gr_info: [4]L3GrInfo = [_]L3GrInfo{.{}} ** 4;
        const mdb_opt = readSideInfo(&bs_frame, &gr_info, hdr);
        if (mdb_opt == null or bs_frame.pos > bs_frame.limit) {
            self.reset();
            return error.InvalidData;
        }
        const main_data_begin = mdb_opt.?;

        var maindata: [MAX_BITRESERVOIR_BYTES + 2304]u8 = undefined;
        var main_bs = restoreReservoir(&self.reserv, &self.reserv_buf, &bs_frame, &maindata, main_data_begin);
        const have_full_reservoir = self.reserv >= main_data_begin;

        if (have_full_reservoir) {
            const n_gr: usize = if (hdr_test_mpeg1(hdr)) 2 else 1;
            var grbuf: [2 * 576]f32 = undefined;
            var ist_pos: [2][39]u8 = undefined;
            var scf: [40]f32 = undefined;
            var syn_buf: [(18 + 15) * 64]f32 = undefined;

            for (0..n_gr) |igr| {
                @memset(&grbuf, 0.0);

                const gr_ptr = gr_info[igr * nch .. (igr + 1) * nch];
                for (0..nch) |ch| {
                    const layer3gr_limit = main_bs.pos + gr_ptr[ch].part_23_length;
                    decodeScalefactors(hdr, &ist_pos[ch], &main_bs, &gr_ptr[ch], &scf, ch);
                    decodeHuffman(grbuf[ch * 576 .. (ch + 1) * 576], &main_bs, &gr_ptr[ch], &scf, layer3gr_limit);
                }

                if (hdr_test_i_stereo(hdr)) {
                    intensityStereo(grbuf[0..576], grbuf[576..1152], &ist_pos[1], &gr_ptr[0], hdr, gr_ptr[1].scalefac_compress);
                } else if (hdr_is_ms_stereo(hdr)) {
                    midsideStereo(grbuf[0..576], grbuf[576..1152], 576);
                }

                for (0..nch) |ch| {
                    const grbuf_ch = grbuf[ch * 576 .. (ch + 1) * 576];
                    var aa_bands: usize = 31;
                    const sr_shift: u5 = @intCast(@intFromBool(hdr_get_my_sample_rate(hdr) == 2));
                    const n_long_bands: usize = (if (gr_ptr[ch].mixed_block_flag != 0) @as(usize, 2) else @as(usize, 0)) << sr_shift;

                    if (gr_ptr[ch].n_short_sfb != 0) {
                        aa_bands = if (n_long_bands > 0) n_long_bands - 1 else 0;
                        reorder(grbuf_ch[n_long_bands * 18 ..], syn_buf[0..], gr_ptr[ch].sfbtab[gr_ptr[ch].n_long_sfb ..]);
                    }

                    antialias(grbuf_ch, aa_bands);
                    imdctGranule(grbuf_ch, &self.mdct_overlap[ch], gr_ptr[ch].block_type, n_long_bands);
                    changeSign(grbuf_ch);
                }

                const pcm_granule_offset = igr * 576 * nch;
                synthGranule(&self.qmf_state, &grbuf, 18, nch, out_interleaved, pcm_granule_offset, &syn_buf);
            }
        }

        saveReservoir(&self.reserv, &self.reserv_buf, &main_bs, &maindata);

        const total_samples = hdr_frame_samples(hdr);

        // If mono, upmix mono channel in-place to stereo interleaved
        if (nch == 1) {
            var i: usize = total_samples;
            while (i > 0) {
                i -= 1;
                const s = out_interleaved[i];
                out_interleaved[i * 2] = s;
                out_interleaved[i * 2 + 1] = s;
            }
        }

        return total_samples;
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
