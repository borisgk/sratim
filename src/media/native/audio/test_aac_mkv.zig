const std = @import("std");
const track_parser = @import("../mkv/track_parser.zig");
const types = @import("../mkv/types.zig");
const block_reader = @import("../mkv/block_reader.zig");
const aac_dec = @import("aac_dec.zig");
const test_report = @import("test_report.zig");

pub fn runAacTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    ref_path: []const u8,
    label: []const u8,
    report_filename: []const u8,
    expected_channels: usize,
) !void {
    const testing = std.testing;

    // 1. Demux MKV natively to find the AAC audio track
    const tracks = try track_parser.parseMkvTracks(allocator, io, file_path);
    defer {
        for (tracks) |*t| t.deinit(allocator);
        allocator.free(tracks);
    }

    var audio_track_opt: ?types.MkvTrackInfo = null;
    for (tracks) |t| {
        if (t.track_type == .Audio) {
            audio_track_opt = t;
            break;
        }
    }
    try testing.expect(audio_track_opt != null);
    const audio_track = audio_track_opt.?;
    try testing.expectEqualStrings("A_AAC", audio_track.codec_id);
    try testing.expectEqual(expected_channels, audio_track.channels);

    // 2. Demux and decode all AAC frames using pure Zig AacDecoder
    const demux_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var decoder = aac_dec.AacDecoder.init();
    decoder.sample_rate = audio_track.sample_rate;
    decoder.channels = audio_track.channels;

    var native_pcm = std.ArrayList(f32).empty;
    defer native_pcm.deinit(allocator);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var current_file_pos: u64 = 0;
    var success_frames: usize = 0;
    var failed_frames: usize = 0;
    var frame_pcm: [2048]f32 = undefined;
    var first_err: ?anyerror = null;

    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            if (decoder.decodeFrame(raw_pkt_buf.items, &frame_pcm)) |n_samples| {
                try native_pcm.appendSlice(allocator, frame_pcm[0 .. n_samples * 2]);
                success_frames += 1;
            } else |err| {
                if (first_err == null) first_err = err;
                failed_frames += 1;
                // Pad with zeros to maintain time synchronization with reference
                const zero_pcm = [_]f32{0.0} ** 2048;
                try native_pcm.appendSlice(allocator, &zero_pcm);
            }
        }
    }

    try testing.expect(success_frames > 0);

    // 3. Load pre-transcoded reference audio PCM (f32le stereo)
    const ref_file = try std.Io.Dir.cwd().openFile(io, ref_path, .{ .mode = .read_only });
    defer ref_file.close(io);

    const ref_stat = try ref_file.stat(io);
    const ref_pcm = try allocator.alloc(f32, ref_stat.size / @sizeOf(f32));
    defer allocator.free(ref_pcm);

    const ref_bytes = std.mem.sliceAsBytes(ref_pcm);
    var ref_buf: [65536]u8 = undefined;
    var ref_reader = ref_file.reader(io, &ref_buf);
    try ref_reader.interface.readSliceAll(ref_bytes);

    // 4. Calculate segment and overall statistics
    // Trim priming frames to align with reference
    const nat_lead = if (native_pcm.items.len > ref_pcm.len) native_pcm.items.len - ref_pcm.len else 0;
    const native_aligned = native_pcm.items[nat_lead..];
    const compare_len = @min(native_aligned.len, ref_pcm.len);
    const nat_aligned = native_aligned[0..compare_len];
    const ff_aligned = ref_pcm[0..compare_len];

    const NUM_SEGMENTS = 10;
    const segment_stats = try test_report.calculateStats(nat_aligned, ff_aligned, 48000, NUM_SEGMENTS, 1.0, allocator);
    defer allocator.free(segment_stats);

    const overall_stats_slice = try test_report.calculateStats(nat_aligned, ff_aligned, 48000, 1, 1.0, allocator);
    defer allocator.free(overall_stats_slice);
    const overall = overall_stats_slice[0];

    const ch_stats = test_report.calculateChannelStats(nat_aligned, ff_aligned, 1.0);

    std.debug.print(
        \\[PER-CHANNEL METRICS: AAC {s}]
        \\  Left Ch:  Native RMS={d:.6}, Ref RMS={d:.6} | Corr r={d:.7} | SNR={d:.2} dB
        \\  Right Ch: Native RMS={d:.6}, Ref RMS={d:.6} | Corr r={d:.7} | SNR={d:.2} dB
        \\
    , .{
        label,
        ch_stats.rms_nat_l,
        ch_stats.rms_ff_l,
        ch_stats.corr_l,
        ch_stats.snr_l,
        ch_stats.rms_nat_r,
        ch_stats.rms_ff_r,
        ch_stats.corr_r,
        ch_stats.snr_r,
    });

    // 5. Display terminal results table and graph
    test_report.printTerminalReport("AAC", label, file_path, overall, segment_stats, success_frames, failed_frames);

    // 6. Generate interactive HTML visual waveform graph report in tmp/
    test_report.generateHtmlReport(io, allocator, .{
        .codec_name = "AAC",
        .label = label,
        .file_path = file_path,
        .out_path = report_filename,
        .sample_rate = 48000,
        .scale_native = 1.0,
        .success_frames = success_frames,
        .failed_frames = failed_frames,
    }, overall, segment_stats, nat_aligned, ff_aligned) catch |err| {
        std.debug.print("Notice: could not write HTML report to {s}: {}\n", .{ report_filename, err });
    };
    std.debug.print("[HTML Report] Generated visual waveform report at: {s}\n", .{report_filename});

    // 7. Verify quality thresholds
    try testing.expectEqual(@as(usize, 0), failed_frames);
    try testing.expect(overall.correlation > 0.95);
}

test "AacDecoder test_video_aac_51.mkv vs pre-transcoded reference" {
    const testing = std.testing;
    try runAacTest(testing.allocator, testing.io, "testvideo/test_video_aac_51.mkv", "testvideo/test_video_aac_51_ref.pcm", "5.1 Surround", "tmp/aac_51_decoding_report.html", 6);
}

test "AacDecoder test_video_h264_aac_stereo.mkv vs pre-transcoded reference" {
    const testing = std.testing;
    try runAacTest(testing.allocator, testing.io, "testvideo/test_video_h264_aac_stereo.mkv", "testvideo/test_video_h264_aac_stereo_ref.pcm", "2.0 Stereo", "tmp/aac_stereo_decoding_report.html", 2);
}
