const std = @import("std");
const track_parser = @import("../mkv/track_parser.zig");
const types = @import("../mkv/types.zig");
const block_reader = @import("../mkv/block_reader.zig");
const eac3_dec = @import("eac3_dec.zig");
const test_report = @import("test_report.zig");
const c = @import("../../../core/c.zig").c;

pub fn runEac3Test(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    label: []const u8,
    report_filename: []const u8,
    expected_channels: usize,
) !void {
    const testing = std.testing;

    // 1. Demux MKV natively to find the EAC-3 audio track
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
    try testing.expectEqualStrings("A_EAC3", audio_track.codec_id);
    try testing.expectEqual(expected_channels, audio_track.channels);

    // 2. Demux and decode all EAC-3 frames using pure Zig Eac3Decoder
    const demux_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var eac3_decoder = eac3_dec.Eac3Decoder.init();

    var native_pcm = std.ArrayList(f32).empty;
    defer native_pcm.deinit(allocator);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var current_file_pos: u64 = 0;
    var num_audio_frames: usize = 0;
    var success_frames: usize = 0;
    var failed_frames: usize = 0;
    var frame_pcm: [1536 * 2]f32 = undefined;

    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            const n_samples = eac3_decoder.decodeFrame(raw_pkt_buf.items, &frame_pcm) catch |err| {
                failed_frames += 1;
                std.debug.print("EAC-3 decode error frame {d}: {}\n", .{ num_audio_frames, err });
                num_audio_frames += 1;
                continue;
            };

            success_frames += 1;
            try native_pcm.appendSlice(allocator, frame_pcm[0 .. n_samples * 2]);
            num_audio_frames += 1;
        }
    }

    try testing.expect(num_audio_frames > 0);

    // 3. Decode the same file with FFmpeg libavcodec for reference
    var in_fmt_ctx: ?*c.AVFormatContext = null;
    const c_file_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file_path);

    if (c.avformat_open_input(&in_fmt_ctx, c_file_path.ptr, null, null) < 0) return error.OpenInputFailed;
    defer c.avformat_close_input(&in_fmt_ctx);

    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.FindStreamInfoFailed;

    var ff_audio_stream_idx: ?usize = null;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            ff_audio_stream_idx = i;
            break;
        }
    }
    try testing.expect(ff_audio_stream_idx != null);
    const audio_stream = in_fmt_ctx.?.streams[ff_audio_stream_idx.?];

    const codec = c.avcodec_find_decoder(audio_stream.*.codecpar.*.codec_id) orelse return error.DecoderNotFound;
    var codec_ctx = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&codec_ctx);

    if (c.avcodec_parameters_to_context(codec_ctx, audio_stream.*.codecpar) < 0) return error.ParametersToContextFailed;

    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.OpenCodecFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&pkt);

    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);

    var ffmpeg_pcm = std.ArrayList(f32).empty;
    defer ffmpeg_pcm.deinit(allocator);

    const LEVEL_3DB: f32 = 0.7071067811865475;

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == @as(c_int, @intCast(ff_audio_stream_idx.?))) {
            if (c.avcodec_send_packet(codec_ctx, pkt) < 0) return error.SendPacketFailed;
            while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
                const nb_samples: usize = @intCast(frame.*.nb_samples);
                const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));
                const ch_count = if (@hasDecl(c, "AVChannelLayout")) frame.*.ch_layout.nb_channels else frame.*.channels;

                if (ch_count >= 6) {
                    // 5.1 Surround downmix to stereo (matching ITU-R BS.775 / Eac3Decoder downmix)
                    const l = data[0];
                    const r = data[1];
                    const center = data[2];
                    const ls = data[4];
                    const rs = data[5];
                    for (0..nb_samples) |s| {
                        try ffmpeg_pcm.append(allocator, l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB);
                        try ffmpeg_pcm.append(allocator, r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB);
                    }
                } else {
                    // 2.0 Stereo
                    const ch0 = data[0];
                    const ch1 = data[1];
                    for (0..nb_samples) |s| {
                        try ffmpeg_pcm.append(allocator, ch0[s]);
                        try ffmpeg_pcm.append(allocator, ch1[s]);
                    }
                }
            }
        }
    }

    _ = c.avcodec_send_packet(codec_ctx, null);
    while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
        const nb_samples: usize = @intCast(frame.*.nb_samples);
        const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));
        const ch_count = if (@hasDecl(c, "AVChannelLayout")) frame.*.ch_layout.nb_channels else frame.*.channels;

        if (ch_count >= 6) {
            const l = data[0];
            const r = data[1];
            const center = data[2];
            const ls = data[4];
            const rs = data[5];
            for (0..nb_samples) |s| {
                try ffmpeg_pcm.append(allocator, l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB);
                try ffmpeg_pcm.append(allocator, r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB);
            }
        } else {
            const ch0 = data[0];
            const ch1 = data[1];
            for (0..nb_samples) |s| {
                try ffmpeg_pcm.append(allocator, ch0[s]);
                try ffmpeg_pcm.append(allocator, ch1[s]);
            }
        }
    }

    // 4. Calculate segment and overall statistics
    // Trim priming delay (256 samples = 512 stereo floats) to align with FFmpeg
    const nat_aligned = if (native_pcm.items.len >= 512)
        native_pcm.items[512..@min(native_pcm.items.len, 512 + ffmpeg_pcm.items.len)]
    else
        native_pcm.items;

    const ff_aligned = ffmpeg_pcm.items[0..nat_aligned.len];

    const NUM_SEGMENTS = 10;
    const segment_stats = try test_report.calculateStats(nat_aligned, ff_aligned, 48000, NUM_SEGMENTS, 2.0, allocator);
    defer allocator.free(segment_stats);

    const overall_stats_slice = try test_report.calculateStats(nat_aligned, ff_aligned, 48000, 1, 2.0, allocator);
    defer allocator.free(overall_stats_slice);
    const overall = overall_stats_slice[0];

    const ch_stats = test_report.calculateChannelStats(nat_aligned, ff_aligned, 2.0);

    std.debug.print(
        \\[PER-CHANNEL METRICS: EAC-3 {s}]
        \\  Left Ch:  Native RMS={d:.6}, FFmpeg RMS={d:.6} | Corr r={d:.7} | SNR={d:.2} dB
        \\  Right Ch: Native RMS={d:.6}, FFmpeg RMS={d:.6} | Corr r={d:.7} | SNR={d:.2} dB
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
    test_report.printTerminalReport("E-AC-3", label, file_path, overall, segment_stats, success_frames, failed_frames);

    // 6. Generate interactive HTML visual waveform graph report in tmp/
    test_report.generateHtmlReport(io, allocator, .{
        .codec_name = "E-AC-3",
        .label = label,
        .file_path = file_path,
        .out_path = report_filename,
        .sample_rate = 48000,
        .scale_native = 2.0,
        .success_frames = success_frames,
        .failed_frames = failed_frames,
    }, overall, segment_stats, nat_aligned, ff_aligned) catch |err| {
        std.debug.print("Notice: could not write HTML report to {s}: {}\n", .{ report_filename, err });
    };
    std.debug.print("[HTML Report] Generated visual waveform report at: {s}\n", .{report_filename});

    // 7. Verify quality thresholds
    try testing.expectEqual(@as(usize, 0), failed_frames);
    try testing.expect(overall.correlation > 0.99);
}

test "Eac3Decoder test_video_eac3_stereo.mkv vs FFmpeg reference" {
    const testing = std.testing;
    try runEac3Test(testing.allocator, testing.io, "testvideo/test_video_eac3_stereo.mkv", "2.0 Stereo", "tmp/eac3_stereo_decoding_report.html", 2);
}

test "Eac3Decoder test_video_eac3_51.mkv vs FFmpeg reference" {
    const testing = std.testing;
    try runEac3Test(testing.allocator, testing.io, "testvideo/test_video_eac3_51.mkv", "5.1 Surround", "tmp/eac3_51_decoding_report.html", 6);
}
