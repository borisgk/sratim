const std = @import("std");
const isobmff = @import("isobmff.zig");

pub const IdentityMatrix = [_]u8{
    0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
};

/// Helper to write an ISOBMFF Box into a dynamic buffer.
pub fn appendBox(out: *std.ArrayList(u8), allocator: std.mem.Allocator, box_type: *const [4]u8, payload: []const u8) !void {
    const size: u32 = @intCast(payload.len + 8);
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], size, .big);
    @memcpy(hdr[4..8], box_type);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, payload);
}

/// Generates the fMP4 initialization segment (ftyp + moov with mvex/trex and source codec descriptions).
pub fn buildInitSegment(
    allocator: std.mem.Allocator,
    video_track: isobmff.Mp4MediaTrack,
    audio_track_opt: ?isobmff.Mp4MediaTrack,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    // 1. FTYP Box (28 bytes)
    const ftyp_payload = [_]u8{
        'i', 's', 'o', 'm', // major brand
        0x00, 0x00, 0x02, 0x00, // minor version = 512
        'i', 's', 'o', 'm', // compatible brand 1
        'i', 's', 'o', '6', // compatible brand 2
        'm', 'p', '4', '1', // compatible brand 3
        'd', 'a', 's', 'h', // compatible brand 4
    };
    try appendBox(&out, allocator, "ftyp", &ftyp_payload);

    // 2. MOOV Box
    var moov_buf = std.ArrayList(u8).empty;
    defer moov_buf.deinit(allocator);

    // 2.1 MVHD Box
    var mvhd_payload = std.ArrayList(u8).empty;
    defer mvhd_payload.deinit(allocator);

    var mvhd_hdr: [100]u8 = [_]u8{0} ** 100;
    // version = 0, flags = 0
    std.mem.writeInt(u32, mvhd_hdr[12..16], 1000, .big); // timescale = 1000
    std.mem.writeInt(u32, mvhd_hdr[16..20], 0, .big); // duration = 0 (fragmented)
    std.mem.writeInt(u32, mvhd_hdr[20..24], 0x00010000, .big); // rate = 1.0
    std.mem.writeInt(u16, mvhd_hdr[24..26], 0x0100, .big); // volume = 1.0
    @memcpy(mvhd_hdr[36..72], &IdentityMatrix);
    const next_track_id: u32 = if (audio_track_opt) |at| @max(video_track.track_id, at.track_id) + 1 else video_track.track_id + 1;
    std.mem.writeInt(u32, mvhd_hdr[96..100], next_track_id, .big);
    try appendBox(&moov_buf, allocator, "mvhd", &mvhd_hdr);

    // 2.2 MVEX Box (Movie Extends Box)
    var mvex_buf = std.ArrayList(u8).empty;
    defer mvex_buf.deinit(allocator);

    // TREX for Video
    var trex_video: [24]u8 = [_]u8{0} ** 24;
    std.mem.writeInt(u32, trex_video[4..8], video_track.track_id, .big);
    std.mem.writeInt(u32, trex_video[8..12], 1, .big); // default sample description index = 1
    try appendBox(&mvex_buf, allocator, "trex", &trex_video);

    // TREX for Audio
    if (audio_track_opt) |at| {
        var trex_audio: [24]u8 = [_]u8{0} ** 24;
        std.mem.writeInt(u32, trex_audio[4..8], at.track_id, .big);
        std.mem.writeInt(u32, trex_audio[8..12], 1, .big);
        try appendBox(&mvex_buf, allocator, "trex", &trex_audio);
    }
    try appendBox(&moov_buf, allocator, "mvex", mvex_buf.items);

    // 2.3 TRAK for Video
    const video_trak = try buildTrakBox(allocator, video_track, true);
    defer allocator.free(video_trak);
    try moov_buf.appendSlice(allocator, video_trak);

    // 2.4 TRAK for Audio (if present)
    if (audio_track_opt) |at| {
        const audio_trak = try buildTrakBox(allocator, at, false);
        defer allocator.free(audio_trak);
        try moov_buf.appendSlice(allocator, audio_trak);
    }

    try appendBox(&out, allocator, "moov", moov_buf.items);

    return try out.toOwnedSlice(allocator);
}

fn buildTrakBox(
    allocator: std.mem.Allocator,
    track: isobmff.Mp4MediaTrack,
    is_video: bool,
) ![]u8 {
    var trak_buf = std.ArrayList(u8).empty;
    defer trak_buf.deinit(allocator);

    // TKHD
    var tkhd_payload: [84]u8 = [_]u8{0} ** 84;
    tkhd_payload[3] = 0x07; // flags = Track_enabled | Track_in_movie | Track_in_preview
    std.mem.writeInt(u32, tkhd_payload[12..16], track.track_id, .big);
    std.mem.writeInt(u32, tkhd_payload[20..24], 0, .big); // duration = 0
    if (!is_video) {
        std.mem.writeInt(u16, tkhd_payload[36..38], 0x0100, .big); // volume = 1.0 for audio
    }
    @memcpy(tkhd_payload[40..76], &IdentityMatrix);
    if (is_video) {
        std.mem.writeInt(u32, tkhd_payload[76..80], track.width << 16, .big);
        std.mem.writeInt(u32, tkhd_payload[80..84], track.height << 16, .big);
    }
    try appendBox(&trak_buf, allocator, "tkhd", &tkhd_payload);

    // MDIA
    var mdia_buf = std.ArrayList(u8).empty;
    defer mdia_buf.deinit(allocator);

    // MDHD
    var mdhd_payload: [24]u8 = [_]u8{0} ** 24;
    std.mem.writeInt(u32, mdhd_payload[12..16], track.timescale, .big);
    std.mem.writeInt(u32, mdhd_payload[16..20], 0, .big); // duration = 0
    std.mem.writeInt(u16, mdhd_payload[20..22], 0x55C4, .big); // language = und
    try appendBox(&mdia_buf, allocator, "mdhd", &mdhd_payload);

    // HDLR
    var hdlr_payload: [33]u8 = [_]u8{0} ** 33;
    if (is_video) {
        @memcpy(hdlr_payload[8..12], "vide");
        @memcpy(hdlr_payload[24..33], "Video\x00\x00\x00\x00");
    } else {
        @memcpy(hdlr_payload[8..12], "soun");
        @memcpy(hdlr_payload[24..33], "Sound\x00\x00\x00\x00");
    }
    try appendBox(&mdia_buf, allocator, "hdlr", &hdlr_payload);

    // MINF
    var minf_buf = std.ArrayList(u8).empty;
    defer minf_buf.deinit(allocator);

    if (is_video) {
        var vmhd_payload: [12]u8 = [_]u8{0} ** 12;
        vmhd_payload[3] = 0x01; // flags = 1
        try appendBox(&minf_buf, allocator, "vmhd", &vmhd_payload);
    } else {
        var smhd_payload: [8]u8 = [_]u8{0} ** 8;
        try appendBox(&minf_buf, allocator, "smhd", &smhd_payload);
    }

    // DINF with DREF
    var dref_payload = std.ArrayList(u8).empty;
    defer dref_payload.deinit(allocator);

    var dref_hdr: [8]u8 = [_]u8{0} ** 8;
    std.mem.writeInt(u32, dref_hdr[4..8], 1, .big); // entry count = 1
    try dref_payload.appendSlice(allocator, &dref_hdr);

    var url_payload: [4]u8 = [_]u8{ 0, 0, 0, 1 }; // flags = 1 (self-contained)
    try appendBox(&dref_payload, allocator, "url ", &url_payload);

    var dinf_buf = std.ArrayList(u8).empty;
    defer dinf_buf.deinit(allocator);
    try appendBox(&dinf_buf, allocator, "dref", dref_payload.items);
    try appendBox(&minf_buf, allocator, "dinf", dinf_buf.items);

    // STBL
    var stbl_buf = std.ArrayList(u8).empty;
    defer stbl_buf.deinit(allocator);

    // STSD from source file
    try stbl_buf.appendSlice(allocator, track.stsd_raw);

    // Empty STTS, STSC, STSZ, STCO
    const empty_table: [8]u8 = [_]u8{0} ** 8;
    try appendBox(&stbl_buf, allocator, "stts", &empty_table);
    try appendBox(&stbl_buf, allocator, "stsc", &empty_table);
    var empty_stsz: [12]u8 = [_]u8{0} ** 12;
    try appendBox(&stbl_buf, allocator, "stsz", &empty_stsz);
    try appendBox(&stbl_buf, allocator, "stco", &empty_table);

    try appendBox(&minf_buf, allocator, "stbl", stbl_buf.items);
    try appendBox(&mdia_buf, allocator, "minf", minf_buf.items);
    try appendBox(&trak_buf, allocator, "mdia", mdia_buf.items);

    var final_trak = std.ArrayList(u8).empty;
    errdefer final_trak.deinit(allocator);
    try appendBox(&final_trak, allocator, "trak", trak_buf.items);
    return try final_trak.toOwnedSlice(allocator);
}

/// Builds an fMP4 fragment header (moof box) and mdat header.
/// Returns the complete header bytes to write before streaming sample payloads.
pub fn buildFragmentHeader(
    allocator: std.mem.Allocator,
    seq_num: u32,
    video_track: isobmff.Mp4MediaTrack,
    video_samples: []const isobmff.MediaSample,
    base_video_dts: u64,
    audio_track_opt: ?isobmff.Mp4MediaTrack,
    audio_samples: []const isobmff.MediaSample,
    base_audio_dts: u64,
    total_video_payload_bytes: usize,
    total_audio_payload_bytes: usize,
) ![]u8 {
    // Two-pass calculation to resolve exact moof data_offset
    // Pass 1: Build moof with data_offset = 0 to measure exact moof size
    const initial_moof = try buildMoofBox(
        allocator,
        seq_num,
        video_track,
        video_samples,
        base_video_dts,
        audio_track_opt,
        audio_samples,
        base_audio_dts,
        0,
        0,
    );
    defer allocator.free(initial_moof);

    const moof_size = initial_moof.len;
    const video_data_offset: u32 = @intCast(moof_size + 8); // 8 is mdat box header size
    const audio_data_offset: u32 = @intCast(moof_size + 8 + total_video_payload_bytes);

    // Pass 2: Build final moof with exact data offsets
    const final_moof = try buildMoofBox(
        allocator,
        seq_num,
        video_track,
        video_samples,
        base_video_dts,
        audio_track_opt,
        audio_samples,
        base_audio_dts,
        video_data_offset,
        audio_data_offset,
    );
    defer allocator.free(final_moof);

    // Build MDAT Header (8 bytes)
    const total_mdat_size: u32 = @intCast(8 + total_video_payload_bytes + total_audio_payload_bytes);
    var mdat_hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, mdat_hdr[0..4], total_mdat_size, .big);
    @memcpy(mdat_hdr[4..8], "mdat");

    var result = try allocator.alloc(u8, final_moof.len + 8);
    @memcpy(result[0..final_moof.len], final_moof);
    @memcpy(result[final_moof.len..], &mdat_hdr);
    return result;
}

fn buildMoofBox(
    allocator: std.mem.Allocator,
    seq_num: u32,
    video_track: isobmff.Mp4MediaTrack,
    video_samples: []const isobmff.MediaSample,
    base_video_dts: u64,
    audio_track_opt: ?isobmff.Mp4MediaTrack,
    audio_samples: []const isobmff.MediaSample,
    base_audio_dts: u64,
    video_data_offset: u32,
    audio_data_offset: u32,
) ![]u8 {
    var moof_buf = std.ArrayList(u8).empty;
    defer moof_buf.deinit(allocator);

    // MFHD Box
    var mfhd_payload: [8]u8 = [_]u8{0} ** 8;
    std.mem.writeInt(u32, mfhd_payload[4..8], seq_num, .big);
    try appendBox(&moof_buf, allocator, "mfhd", &mfhd_payload);

    // Video TRAF Box
    if (video_samples.len > 0) {
        const video_traf = try buildTrafBox(allocator, video_track, video_samples, base_video_dts, video_data_offset, true);
        defer allocator.free(video_traf);
        try moof_buf.appendSlice(allocator, video_traf);
    }

    // Audio TRAF Box
    if (audio_track_opt != null and audio_samples.len > 0) {
        const audio_traf = try buildTrafBox(allocator, audio_track_opt.?, audio_samples, base_audio_dts, audio_data_offset, false);
        defer allocator.free(audio_traf);
        try moof_buf.appendSlice(allocator, audio_traf);
    }

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try appendBox(&result, allocator, "moof", moof_buf.items);
    return try result.toOwnedSlice(allocator);
}

fn buildTrafBox(
    allocator: std.mem.Allocator,
    track: isobmff.Mp4MediaTrack,
    samples: []const isobmff.MediaSample,
    base_dts: u64,
    data_offset: u32,
    is_video: bool,
) ![]u8 {
    var traf_buf = std.ArrayList(u8).empty;
    defer traf_buf.deinit(allocator);

    // TFHD (default-base-is-moof = 0x020000)
    var tfhd_payload: [8]u8 = [_]u8{ 0, 0x02, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u32, tfhd_payload[4..8], track.track_id, .big);
    try appendBox(&traf_buf, allocator, "tfhd", &tfhd_payload);

    // TFDT (version 1 64-bit baseMediaDecodeTime)
    var tfdt_payload: [12]u8 = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, tfdt_payload[4..12], base_dts, .big);
    try appendBox(&traf_buf, allocator, "tfdt", &tfdt_payload);

    // TRUN
    var trun_buf = std.ArrayList(u8).empty;
    defer trun_buf.deinit(allocator);

    var has_ctts = false;
    if (is_video) {
        for (samples) |s| {
            if (s.ctts_offset != 0) {
                has_ctts = true;
                break;
            }
        }
    }

    // Flags:
    // 0x000001: data-offset-present
    // 0x000100: sample-duration-present
    // 0x000200: sample-size-present
    // 0x000400: sample-flags-present (used for video sync/non-sync)
    // 0x000800: sample-composition-time-offsets-present (if has_ctts)
    var trun_flags: u32 = 0x000301; // data-offset + duration + size
    if (is_video) {
        trun_flags |= 0x000400; // sample flags for video
        if (has_ctts) {
            trun_flags |= 0x000800; // composition time offset
        }
    }

    var trun_hdr: [12]u8 = undefined;
    trun_hdr[0] = 0; // version 0
    std.mem.writeInt(u24, trun_hdr[1..4], @intCast(trun_flags), .big);
    std.mem.writeInt(u32, trun_hdr[4..8], @intCast(samples.len), .big);
    std.mem.writeInt(u32, trun_hdr[8..12], data_offset, .big);
    try trun_buf.appendSlice(allocator, &trun_hdr);

    for (samples) |s| {
        var row_buf: [16]u8 = undefined;
        var row_len: usize = 8;
        std.mem.writeInt(u32, row_buf[0..4], s.dts_delta, .big);
        std.mem.writeInt(u32, row_buf[4..8], s.size, .big);

        if (is_video) {
            // Sample flags:
            // 0x02000000: sample_is_non_sync_sample = 1 (P/B frame)
            // 0x00000000 or 0x01000000: sync sample / IDR
            const s_flags: u32 = if (s.is_sync) 0x02000000 else 0x01010000;
            std.mem.writeInt(u32, row_buf[8..12], s_flags, .big);
            row_len = 12;

            if (has_ctts) {
                std.mem.writeInt(u32, row_buf[12..16], @bitCast(s.ctts_offset), .big);
                row_len = 16;
            }
        }
        try trun_buf.appendSlice(allocator, row_buf[0..row_len]);
    }

    try appendBox(&traf_buf, allocator, "trun", trun_buf.items);

    var final_traf = std.ArrayList(u8).empty;
    errdefer final_traf.deinit(allocator);
    try appendBox(&final_traf, allocator, "traf", traf_buf.items);
    return try final_traf.toOwnedSlice(allocator);
}

test "buildInitSegment ftyp and moov structure" {
    const allocator = std.testing.allocator;

    const mock_stsd = [_]u8{ 0, 0, 0, 16, 's', 't', 's', 'd', 0, 0, 0, 0, 0, 0, 0, 1 };
    const stsd_raw = try allocator.dupe(u8, &mock_stsd);

    const video_track = isobmff.Mp4MediaTrack{
        .track_id = 1,
        .stream_idx = 0,
        .handler_type = "vide".*,
        .timescale = 30000,
        .duration = 300000,
        .width = 1920,
        .height = 1080,
        .stsd_raw = stsd_raw,
        .samples = &.{},
        .sync_sample_indices = &.{},
    };
    var mut_video = video_track;
    defer mut_video.deinit(allocator);

    const init_seg = try buildInitSegment(allocator, mut_video, null);
    defer allocator.free(init_seg);

    try std.testing.expect(init_seg.len >= 28);
    try std.testing.expectEqualStrings("ftyp", init_seg[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "moov") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "mvex") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "trak") != null);
}

test "buildFragmentHeader moof and mdat structure" {
    const allocator = std.testing.allocator;

    const mock_stsd = [_]u8{ 0, 0, 0, 16, 's', 't', 's', 'd', 0, 0, 0, 0, 0, 0, 0, 1 };
    const stsd_raw = try allocator.dupe(u8, &mock_stsd);

    const video_track = isobmff.Mp4MediaTrack{
        .track_id = 1,
        .stream_idx = 0,
        .handler_type = "vide".*,
        .timescale = 1000,
        .duration = 10000,
        .width = 640,
        .height = 360,
        .stsd_raw = stsd_raw,
        .samples = &.{},
        .sync_sample_indices = &.{},
    };
    var mut_video = video_track;
    defer mut_video.deinit(allocator);

    const video_samples = [_]isobmff.MediaSample{
        .{ .dts_delta = 33, .dts = 0, .pts = 0, .pts_sec = 0.0, .offset = 100, .size = 500, .is_sync = true },
        .{ .dts_delta = 33, .dts = 33, .pts = 33, .pts_sec = 0.033, .offset = 600, .size = 200, .is_sync = false },
    };

    const frag_hdr = try buildFragmentHeader(
        allocator,
        1,
        mut_video,
        &video_samples,
        0,
        null,
        &.{},
        0,
        700,
        0,
    );
    defer allocator.free(frag_hdr);

    try std.testing.expect(frag_hdr.len > 8);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "moof") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "mfhd") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "traf") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "tfhd") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "tfdt") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "trun") != null);
    try std.testing.expect(std.mem.indexOf(u8, frag_hdr, "mdat") != null);
}
