const std = @import("std");
const track_parser = @import("../mkv/track_parser.zig");
const types = @import("../mkv/types.zig");
const block_reader = @import("../mkv/block_reader.zig");
const mp3_dec = @import("mp3_dec.zig");
const test_report = @import("test_report.zig");

pub fn runMp3Test(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    ref_path: []const u8,
    label: []const u8,
    report_filename: []const u8,
    expected_channels: u16,
) !void {
    const testing = std.testing;

    // 1. Demux MKV natively to find the MP3 audio track
    const tracks = track_parser.parseMkvTracks(allocator, io, file_path) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Notice: test video {s} not found, skipping.\n", .{file_path});
            return;
        }
        return err;
    };
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
    try testing.expectEqualStrings("A_MPEG/L3", audio_track.codec_id);
    try testing.expectEqual(expected_channels, audio_track.channels);
    try testing.expectEqual(@as(u32, 44100), audio_track.sample_rate);

    // 2. Demux and decode all MP3 frames using pure Zig Mp3Decoder
    const demux_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var mp3_decoder = mp3_dec.Mp3Decoder.init();

    var native_pcm = std.ArrayList(f32).empty;
    defer native_pcm.deinit(allocator);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var current_file_pos: u64 = 0;
    var num_audio_frames: usize = 0;
    var frame_pcm: [1152 * 2]f32 = undefined;

    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            const n_samples = mp3_decoder.decodeFrame(raw_pkt_buf.items, &frame_pcm) catch |err| {
                std.debug.print("MP3 decode error at frame {d}: {s}\n", .{ num_audio_frames, @errorName(err) });
                continue;
            };

            try native_pcm.appendSlice(allocator, frame_pcm[0 .. n_samples * 2]);
            num_audio_frames += 1;
        }
    }

    std.debug.print("Decoded {d} MP3 frames ({d} total stereo samples)\n", .{ num_audio_frames, native_pcm.items.len / 2 });
    try testing.expect(num_audio_frames > 0);

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

    // 4. Alignment & delay matching:
    // MP3 decoders standardly have 529 or 1152 samples of encoder delay (LAME delay)
    // Find optimal offset for best correlation
    const compare_len = @min(native_pcm.items.len, ref_pcm.len);
    if (compare_len > 0) {
        var best_offset: usize = 0;
        var best_corr: f64 = -1.0;

        // Scan delay search window (0 to 1152 samples * 2)
        var offset: usize = 0;
        while (offset <= 2304 and offset + 4000 <= native_pcm.items.len and offset + 4000 <= ref_pcm.len) : (offset += 2) {
            var sum_xy: f64 = 0;
            var sum_x2: f64 = 0;
            var sum_y2: f64 = 0;
            for (0..4000) |i| {
                const x: f64 = native_pcm.items[offset + i];
                const y: f64 = ref_pcm[i];
                sum_xy += x * y;
                sum_x2 += x * x;
                sum_y2 += y * y;
            }
            if (sum_x2 > 0 and sum_y2 > 0) {
                const corr = sum_xy / @sqrt(sum_x2 * sum_y2);
                if (corr > best_corr) {
                    best_corr = corr;
                    best_offset = offset;
                }
            }
        }

        std.debug.print("MP3 alignment: best offset = {d} floats, initial sample correlation = {d:.6}\n", .{ best_offset, best_corr });

        const aligned_nat = native_pcm.items[best_offset..@min(native_pcm.items.len, best_offset + ref_pcm.len)];
        const aligned_ref = ref_pcm[0..aligned_nat.len];

        const NUM_SEGMENTS = 10;
        const segment_stats = try test_report.calculateStats(aligned_nat, aligned_ref, 44100, NUM_SEGMENTS, 1.0, allocator);
        defer allocator.free(segment_stats);

        const overall_stats_slice = try test_report.calculateStats(aligned_nat, aligned_ref, 44100, 1, 1.0, allocator);
        defer allocator.free(overall_stats_slice);
        const overall = overall_stats_slice[0];

        const ch_stats = test_report.calculateChannelStats(aligned_nat, aligned_ref, 1.0);

        std.debug.print(
            \\[PER-CHANNEL METRICS: {s}]
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

        test_report.printTerminalReport("MP3", label, file_path, overall, segment_stats, null, null);

        test_report.generateHtmlReport(io, allocator, .{
            .codec_name = "MP3",
            .label = label,
            .file_path = file_path,
            .out_path = report_filename,
            .sample_rate = 44100,
            .scale_native = 1.0,
        }, overall, segment_stats, aligned_nat, aligned_ref) catch {};

        try testing.expect(overall.correlation > 0.999);
        try testing.expect(overall.snr_db > 100.0);
    }
}

test "Mp3Decoder test_video_mp3_stereo: 2.0 Stereo comparison" {
    const testing = std.testing;
    try runMp3Test(
        testing.allocator,
        testing.io,
        "testvideo/test_video_mp3_stereo.mkv",
        "testvideo/test_video_mp3_stereo_ref.pcm",
        "2.0 Stereo MP3",
        "tmp/mp3_decoding_report.html",
        2,
    );
}
