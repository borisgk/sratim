const std = @import("std");
const tables = @import("tables.zig");
const bit_reader_mod = @import("bit_reader.zig");
const BitReader = bit_reader_mod.BitReader;

pub const DCA_SYNC_16_BE: u32 = 0x7FFE8001;
pub const DCA_SYNC_16_LE: u32 = 0xFE7F0180;
pub const DCA_SYNC_14_BE: u32 = 0x1FFFE800;
pub const DCA_SYNC_14_LE: u32 = 0xFF1F00E8;

pub const AudioMode = enum(u6) {
    mono = 0,
    dual_mono = 1,
    stereo = 2,
    stereo_sumdiff = 3,
    stereo_total = 4,
    surround_3_0 = 5,
    surround_2_1 = 6,
    surround_3_1 = 7,
    surround_2_2 = 8,
    surround_5_0 = 9,
    _,
};

pub const FrameHeader = struct {
    normal_frame: bool,
    crc_present: bool,
    npcmblocks: u32,
    frame_size: u32,
    audio_mode: AudioMode,
    sample_rate: u32,
    bit_rate: i32,
    drc_present: bool,
    ts_present: bool,
    aux_present: bool,
    ext_audio_type: u3,
    ext_audio_present: bool,
    sync_ssf: bool,
    lfe_present: u2,
    predictor_history: bool,
    filter_perfect: bool,
    source_pcm_res: u8,
    es_format: bool,
    sumdiff_front: bool,
    sumdiff_surround: bool,

    nsubframes: u32,
    nchannels: u8,
    nsubbands: [8]u8,
    subband_vq_start: [8]u8,
    joint_intensity_index: [8]u8,
    transition_mode_sel: [8]u2,
    scale_factor_sel: [8]u3,
    bit_allocation_sel: [8]u3,
    quant_index_sel: [8][10]u8,
    scale_factor_adj: [8][10]i32,
};

/// Unpacks 14-bit DCA bitstream into 16-bit format if required.
pub fn unpack14Bit(src: []const u8, dst: []u8) usize {
    var in_bits: u32 = 0;
    var in_buf: u32 = 0;
    var src_idx: usize = 0;
    var dst_idx: usize = 0;

    while (src_idx + 1 < src.len and dst_idx + 1 < dst.len) {
        // Read 14 bits from 16-bit word
        const w = (@as(u16, src[src_idx]) << 8) | src[src_idx + 1];
        src_idx += 2;
        in_buf = (in_buf << 14) | (w & 0x3FFF);
        in_bits += 14;

        while (in_bits >= 16 and dst_idx + 1 < dst.len) {
            in_bits -= 16;
            const out_w = @as(u16, @intCast((in_buf >> @intCast(in_bits)) & 0xFFFF));
            dst[dst_idx] = @intCast(out_w >> 8);
            dst[dst_idx + 1] = @intCast(out_w & 0xFF);
            dst_idx += 2;
        }
    }
    return dst_idx;
}

/// Detects sync word and byte order; returns byte offset of sync and byte swapped if needed.
pub fn findSync(bytes: []const u8) ?struct { offset: usize, is_le: bool, is_14bit: bool } {
    if (bytes.len < 4) return null;
    var i: usize = 0;
    while (i + 4 <= bytes.len) : (i += 1) {
        const w32 = (@as(u32, bytes[i]) << 24) | (@as(u32, bytes[i + 1]) << 16) | (@as(u32, bytes[i + 2]) << 8) | @as(u32, bytes[i + 3]);
        if (w32 == DCA_SYNC_16_BE) {
            return .{ .offset = i, .is_le = false, .is_14bit = false };
        } else if (w32 == DCA_SYNC_16_LE) {
            return .{ .offset = i, .is_le = true, .is_14bit = false };
        } else if (w32 == DCA_SYNC_14_BE) {
            return .{ .offset = i, .is_le = false, .is_14bit = true };
        } else if (w32 == DCA_SYNC_14_LE) {
            return .{ .offset = i, .is_le = true, .is_14bit = true };
        }
    }
    return null;
}

/// Parses bitstream header and primary audio coding header from frame payload (starting at sync word).
pub fn parseHeader(reader: *BitReader) !FrameHeader {
    const sync = try reader.readBits(u32, 32);
    if (sync != DCA_SYNC_16_BE) {
        return error.InvalidSyncWord;
    }

    const normal_frame = (try reader.readBit()) != 0;
    const deficit_samples = try reader.readBits(u5, 5);
    if (deficit_samples != 31) {
        return error.InvalidDeficitSamples;
    }

    const crc_present = (try reader.readBit()) != 0;
    const npcmblocks = (@as(u32, try reader.readBits(u7, 7)) + 1);
    if ((npcmblocks & 7) != 0) {
        return error.InvalidPcmBlocks;
    }

    const frame_size = (@as(u32, try reader.readBits(u14, 14)) + 1);
    if (frame_size < 96) {
        return error.InvalidFrameSize;
    }

    const audio_mode_raw = try reader.readBits(u6, 6);
    if (audio_mode_raw >= 10) {
        return error.UnsupportedAudioMode;
    }
    const audio_mode: AudioMode = @enumFromInt(audio_mode_raw);

    const sr_code = try reader.readBits(u4, 4);
    const sample_rate: u32 = if (sr_code < tables.sample_rates.len) @intCast(tables.sample_rates[sr_code]) else 0;
    if (sample_rate == 0) return error.InvalidSampleRate;

    const br_code = try reader.readBits(u5, 5);
    const bit_rate: i32 = if (br_code < tables.bit_rates.len) tables.bit_rates[br_code] else -1;

    try reader.skipBits(1); // reserved
    const drc_present = (try reader.readBit()) != 0;
    const ts_present = (try reader.readBit()) != 0;
    const aux_present = (try reader.readBit()) != 0;
    try reader.skipBits(1); // hdcd mastering
    const ext_audio_type = try reader.readBits(u3, 3);
    const ext_audio_present = (try reader.readBit()) != 0;
    const sync_ssf = (try reader.readBit()) != 0;
    const lfe_present = try reader.readBits(u2, 2);
    if (lfe_present == 3) return error.InvalidLfeFlag;

    const predictor_history = (try reader.readBit()) != 0;
    if (crc_present) {
        try reader.skipBits(16); // header CRC
    }

    const filter_perfect = (try reader.readBit()) != 0;
    try reader.skipBits(4); // encoder rev
    try reader.skipBits(2); // copy history
    const pcmr_index = try reader.readBits(u3, 3);
    const source_pcm_res = tables.sample_res[pcmr_index];
    const es_format = (pcmr_index & 1) != 0;

    const sumdiff_front = (try reader.readBit()) != 0;
    const sumdiff_surround = (try reader.readBit()) != 0;
    try reader.skipBits(4); // dialnorm

    // Primary audio coding header
    const nsubframes = @as(u32, try reader.readBits(u4, 4)) + 1;
    const nchannels_raw = @as(u8, try reader.readBits(u3, 3)) + 1;
    const expected_channels = tables.audio_mode_nch[audio_mode_raw];
    if (nchannels_raw != expected_channels) {
        return error.InvalidChannelCount;
    }
    const nchannels: u8 = nchannels_raw;

    var nsubbands: [8]u8 = [_]u8{0} ** 8;
    for (0..nchannels) |ch| {
        nsubbands[ch] = @as(u8, try reader.readBits(u5, 5)) + 2;
        if (nsubbands[ch] > 32) return error.InvalidSubbandCount;
    }

    var subband_vq_start: [8]u8 = [_]u8{0} ** 8;
    for (0..nchannels) |ch| {
        subband_vq_start[ch] = @as(u8, try reader.readBits(u5, 5)) + 1;
    }

    var joint_intensity_index: [8]u8 = [_]u8{0} ** 8;
    for (0..nchannels) |ch| {
        joint_intensity_index[ch] = @intCast(try reader.readBits(u3, 3));
    }

    var transition_mode_sel: [8]u2 = [_]u2{0} ** 8;
    for (0..nchannels) |ch| {
        transition_mode_sel[ch] = try reader.readBits(u2, 2);
    }

    var scale_factor_sel: [8]u3 = [_]u3{0} ** 8;
    for (0..nchannels) |ch| {
        scale_factor_sel[ch] = try reader.readBits(u3, 3);
        if (scale_factor_sel[ch] == 7) return error.InvalidScaleFactorSel;
    }

    var bit_allocation_sel: [8]u3 = [_]u3{0} ** 8;
    for (0..nchannels) |ch| {
        bit_allocation_sel[ch] = try reader.readBits(u3, 3);
        if (bit_allocation_sel[ch] == 7) return error.InvalidBitAllocationSel;
    }

    var quant_index_sel: [8][10]u8 = [_][10]u8{[_]u8{0} ** 10} ** 8;
    for (0..10) |n| {
        for (0..nchannels) |ch| {
            quant_index_sel[ch][n] = @intCast(try reader.readBits(u3, tables.quant_index_sel_nbits[n]));
        }
    }

    var scale_factor_adj: [8][10]i32 = [_][10]i32{[_]i32{1 << 22} ** 10} ** 8;
    for (0..10) |n| {
        for (0..nchannels) |ch| {
            if (quant_index_sel[ch][n] < tables.quant_index_group_size[n]) {
                const adj_idx = try reader.readBits(u2, 2);
                scale_factor_adj[ch][n] = tables.scale_factor_adj[adj_idx];
            }
        }
    }

    if (crc_present) {
        try reader.skipBits(16);
    }

    return FrameHeader{
        .normal_frame = normal_frame,
        .crc_present = crc_present,
        .npcmblocks = npcmblocks,
        .frame_size = frame_size,
        .audio_mode = audio_mode,
        .sample_rate = sample_rate,
        .bit_rate = bit_rate,
        .drc_present = drc_present,
        .ts_present = ts_present,
        .aux_present = aux_present,
        .ext_audio_type = ext_audio_type,
        .ext_audio_present = ext_audio_present,
        .sync_ssf = sync_ssf,
        .lfe_present = lfe_present,
        .predictor_history = predictor_history,
        .filter_perfect = filter_perfect,
        .source_pcm_res = source_pcm_res,
        .es_format = es_format,
        .sumdiff_front = sumdiff_front,
        .sumdiff_surround = sumdiff_surround,
        .nsubframes = nsubframes,
        .nchannels = nchannels,
        .nsubbands = nsubbands,
        .subband_vq_start = subband_vq_start,
        .joint_intensity_index = joint_intensity_index,
        .transition_mode_sel = transition_mode_sel,
        .scale_factor_sel = scale_factor_sel,
        .bit_allocation_sel = bit_allocation_sel,
        .quant_index_sel = quant_index_sel,
        .scale_factor_adj = scale_factor_adj,
    };
}

test "parse header from test_dts_5s.dts" {
    const file = std.Io.Dir.cwd().openFile(std.testing.io, "tests/test_dts_5s.dts", .{}) catch return;
    defer file.close(std.testing.io);

    var buf: [4096]u8 = undefined;
    var reader_file = file.reader(std.testing.io, &buf);
    const bytes_read = try reader_file.interface.readSliceShort(&buf);
    try std.testing.expect(bytes_read > 200);

    const sync_info = findSync(buf[0..bytes_read]) orelse return error.SyncNotFound;
    try std.testing.expectEqual(@as(usize, 0), sync_info.offset);
    try std.testing.expect(!sync_info.is_14bit);

    var reader = BitReader.init(buf[sync_info.offset..bytes_read]);
    const hdr = try parseHeader(&reader);
    try std.testing.expect(hdr.sample_rate == 48000 or hdr.sample_rate == 44100);
    try std.testing.expect(hdr.nchannels >= 2);
    try std.testing.expect(hdr.frame_size >= 96);
}

