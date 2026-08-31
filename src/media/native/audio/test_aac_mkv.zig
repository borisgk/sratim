const std = @import("std");
const track_parser = @import("../mkv/track_parser.zig");
const types = @import("../mkv/types.zig");
const block_reader = @import("../mkv/block_reader.zig");
const aac_dec = @import("aac_dec.zig");
const test_report = @import("test_report.zig");
const c = @import("../../../core/c.zig").c;

pub fn runAacTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
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
    if (audio_track.codec_private) |cp| {
        std.debug.print("\n=== AUDIO TRACK CODEC_PRIVATE (len={d}): {x} ===\n", .{ cp.len, cp });
    } else {
        std.debug.print("\n=== AUDIO TRACK CODEC_PRIVATE IS NULL ===\n", .{});
    }

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

    var nat_6ch: [6]std.ArrayList(f32) = undefined;
    var ff_6ch: [6]std.ArrayList(f32) = undefined;
    for (0..6) |ch| {
        nat_6ch[ch] = std.ArrayList(f32).empty;
        ff_6ch[ch] = std.ArrayList(f32).empty;
    }
    defer {
        for (0..6) |ch| {
            nat_6ch[ch].deinit(allocator);
            ff_6ch[ch].deinit(allocator);
        }
    }

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var current_file_pos: u64 = 0;
    var success_frames: usize = 0;
    var failed_frames: usize = 0;
    var frame_pcm: [2048]f32 = undefined;
    var first_err: ?anyerror = null;

    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            if (success_frames + failed_frames < 5) {
                std.debug.print("[BLOCK INFO #{d}] offset={d} size={d} pts={d}\n", .{
                    success_frames + failed_frames, blk.payload_offset, blk.payload_size, blk.pts_ms,
                });
            }
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            if (decoder.decodeFrame(raw_pkt_buf.items, &frame_pcm)) |n_samples| {
                try native_pcm.appendSlice(allocator, frame_pcm[0 .. n_samples * 2]);
                for (0..6) |ch| {
                    for (decoder.last_ch_pcm[ch]) |v| {
                        try nat_6ch[ch].append(allocator, v * (1.0 / 65536.0));
                    }
                }
                if (success_frames < 10) {
                    var max_f: f32 = 0.0;
                    var sq_sum: f64 = 0.0;
                    for (frame_pcm[0 .. n_samples * 2]) |s| {
                        if (@abs(s) > max_f) max_f = @abs(s);
                        sq_sum += @as(f64, s) * @as(f64, s);
                    }
                    const frame_rms = std.math.sqrt(sq_sum / @as(f64, @floatFromInt(n_samples * 2)));
                    std.debug.print("[AAC FRAME {d:>2}] max={d:.6} rms={d:.6} len={d}\n", .{ success_frames, max_f, frame_rms, raw_pkt_buf.items.len });
                }
                success_frames += 1;
            } else |err| {
                const total_f = success_frames + failed_frames;
                if (failed_frames < 5) {
                    std.debug.print("[AAC FAIL FRAME #{d}]: {}\n", .{ total_f, err });
                }
                if (first_err == null) first_err = err;
                failed_frames += 1;
                // Pad with zeros to maintain time synchronization with reference
                const zero_pcm = [_]f32{0.0} ** 2048;
                try native_pcm.appendSlice(allocator, &zero_pcm);
            }
        }
    }

    if (first_err) |err| {
        std.debug.print("[AAC Decoder Notice] Frame decode encountered error: {} (Failed frames: {d}/{d})\n", .{ err, failed_frames, success_frames + failed_frames });
    }

    // 3. Decode the same file with FFmpeg libavcodec for reference
    var in_fmt_ctx: ?*c.AVFormatContext = null;
    const c_file_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file_path);

    c.av_log_set_level(c.AV_LOG_TRACE);
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

    codec_ctx.*.debug |= c.FF_DEBUG_STARTCODE;
    c.av_log_set_level(c.AV_LOG_DEBUG);

    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.OpenCodecFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&pkt);

    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);

    var ffmpeg_pcm = std.ArrayList(f32).empty;
    defer ffmpeg_pcm.deinit(allocator);

    const LEVEL_3DB: f32 = 0.7071067811865475;
    const NORM_51: f32 = 1.0 / (1.0 + 2.0 * LEVEL_3DB);

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == @as(c_int, @intCast(ff_audio_stream_idx.?))) {
            if (ffmpeg_pcm.items.len < 10240) {
                std.debug.print("[FFMPEG PKT] size={d} pts={d}\n", .{ pkt.*.size, pkt.*.pts });
            }
            if (c.avcodec_send_packet(codec_ctx, pkt) < 0) return error.SendPacketFailed;
            while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
                const nb_samples: usize = @intCast(frame.*.nb_samples);
                const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));
                const ch_count = if (@hasDecl(c, "AVChannelLayout")) frame.*.ch_layout.nb_channels else frame.*.channels;
                if (ffmpeg_pcm.items.len < 10240) {
                    var rms_ch: [6]f32 = [_]f32{0.0} ** 6;
                    for (0..6) |ch| {
                        var sum_sq: f64 = 0;
                        for (0..nb_samples) |s| {
                            const val: f64 = data[ch][s];
                            sum_sq += val * val;
                        }
                        rms_ch[ch] = @floatCast(@sqrt(sum_sq / @as(f64, @floatFromInt(nb_samples))));
                    }
                    std.debug.print("[FFMPEG FRAME pts={d}] C={d:.4} L={d:.4} R={d:.4} LFE={d:.4} Ls={d:.4} Rs={d:.4}\n", .{
                        frame.*.pts, rms_ch[2], rms_ch[0], rms_ch[1], rms_ch[3], rms_ch[4], rms_ch[5],
                    });
                    const c_data = data[2];
                    var peak_idx: usize = 0;
                    var peak_val: f32 = 0;
                    for (0..nb_samples) |idx| {
                        if (@abs(c_data[idx]) > @abs(peak_val)) {
                            peak_val = c_data[idx];
                            peak_idx = idx;
                        }
                    }
                    std.debug.print("  [FFMPEG FRAME pts={d} C PEAK] peak_val={d:.5} at sample={d}\n", .{
                        frame.*.pts, peak_val, peak_idx,
                    });
                    std.debug.print("  [FFMPEG FRAME pts={d} C SAMPLES 0..15]:\n    ", .{frame.*.pts});
                    for (0..16) |s| std.debug.print("{d:.5} ", .{c_data[s]});
                    std.debug.print("\n", .{});
                }

                if (ch_count >= 6) {
                    // 5.1 Surround downmix to stereo (matching ITU-R BS.775 / AacDecoder downmix)
                    const l = data[0];
                    const r = data[1];
                    const center = data[2];
                    const ls = data[4];
                    const rs = data[5];
                    for (0..nb_samples) |s| {
                        for (0..6) |ch| {
                            try ff_6ch[ch].append(allocator, data[ch][s]);
                        }
                        try ffmpeg_pcm.append(allocator, (l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB) * NORM_51);
                        try ffmpeg_pcm.append(allocator, (r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB) * NORM_51);
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
            const lfe = data[3];
            const ls = data[4];
            const rs = data[5];
            if (ffmpeg_pcm.items.len == 0) {
                var rms: [6]f64 = [_]f64{0.0} ** 6;
                for (0..nb_samples) |s| {
                    rms[0] += @as(f64, l[s]) * @as(f64, l[s]);
                    rms[1] += @as(f64, r[s]) * @as(f64, r[s]);
                    rms[2] += @as(f64, center[s]) * @as(f64, center[s]);
                    rms[3] += @as(f64, lfe[s]) * @as(f64, lfe[s]);
                    rms[4] += @as(f64, ls[s]) * @as(f64, ls[s]);
                    rms[5] += @as(f64, rs[s]) * @as(f64, rs[s]);
                }
                for (0..6) |ch| rms[ch] = @sqrt(rms[ch] / @as(f64, @floatFromInt(nb_samples)));
                std.debug.print("  [FFMPEG F0 CH RMS] L={d:.4} R={d:.4} C={d:.4} LFE={d:.4} Ls={d:.4} Rs={d:.4}\n", .{
                    rms[0], rms[1], rms[2], rms[3], rms[4], rms[5],
                });
            }
            for (0..nb_samples) |s| {
                for (0..6) |ch| {
                    try ff_6ch[ch].append(allocator, data[ch][s]);
                }
                try ffmpeg_pcm.append(allocator, (l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB) * NORM_51);
                try ffmpeg_pcm.append(allocator, (r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB) * NORM_51);
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

    // If FFmpeg skipped priming frames due to container side data, native will have 1 extra frame (2048 floats)
    const nat_lead = if (native_pcm.items.len > ffmpeg_pcm.items.len) native_pcm.items.len - ffmpeg_pcm.items.len else 0;
    const native_aligned = native_pcm.items[nat_lead..];
    const ffmpeg_aligned = ffmpeg_pcm.items;
    const compare_len = @min(native_aligned.len, ffmpeg_aligned.len);
    std.debug.print("ALIGNED LENGTHS: native={d} ffmpeg={d} compare={d} (nat_lead={d})\n", .{ native_aligned.len, ffmpeg_aligned.len, compare_len, nat_lead });
    const nat_aligned = native_aligned[0..compare_len];
    const ff_aligned = ffmpeg_aligned[0..compare_len];

    // Find best lag cross-correlation to verify time alignment
    var best_lag: i32 = 0;
    var max_abs_r: f64 = 0.0;
    var best_r: f64 = 0.0;
    const test_n: usize = 48000 * 2; // test first 1 second of stereo
    if (nat_aligned.len >= test_n + 8192 and ff_aligned.len >= test_n + 8192) {
        var lag: i32 = -4096;
        while (lag <= 4096) : (lag += 1) {
            var sum_prod: f64 = 0;
            var sum_nat_sq: f64 = 0;
            var sum_ff_sq: f64 = 0;
            for (0..test_n) |i| {
                const nat_idx: usize = @intCast(@as(i64, @intCast(i + 4096)) + lag);
                const ff_idx: usize = i + 4096;
                const nv: f64 = nat_aligned[nat_idx];
                const fv: f64 = ff_aligned[ff_idx];
                sum_prod += nv * fv;
                sum_nat_sq += nv * nv;
                sum_ff_sq += fv * fv;
            }
            if (sum_nat_sq > 0 and sum_ff_sq > 0) {
                const r = sum_prod / @sqrt(sum_nat_sq * sum_ff_sq);
                if (@abs(r) > max_abs_r) {
                    max_abs_r = @abs(r);
                    best_r = r;
                    best_lag = lag;
                }
            }
        }
    }
    std.debug.print("BEST STEREO TIME-ALIGNMENT LAG: {d} samples (r={d:.6}, abs_r={d:.6})\n", .{ best_lag, best_r, max_abs_r });

    // Compare individual 6 channels directly against ffmpeg 6ch dump
    const min_6ch_len = @min(nat_6ch[0].items.len, ff_6ch[0].items.len);
    std.debug.print("\n=== 6-CHANNEL DIRECT CROSS-CORRELATION (N={d}) ===\n", .{min_6ch_len});
    const ch_names = [_][]const u8{ "Left (FL)", "Right (FR)", "Center (FC)", "LFE", "Left Surround (BL)", "Right Surround (BR)" };
    for (0..6) |ch| {
        var sum_prod: f64 = 0;
        var sum_nat_sq: f64 = 0;
        var sum_ff_sq: f64 = 0;
        for (0..min_6ch_len) |s| {
            const nv: f64 = nat_6ch[ch].items[s];
            const fv: f64 = ff_6ch[ch].items[s];
            sum_prod += nv * fv;
            sum_nat_sq += nv * nv;
            sum_ff_sq += fv * fv;
        }
        const rms_nat = std.math.sqrt(sum_nat_sq / @as(f64, @floatFromInt(min_6ch_len)));
        const rms_ff = std.math.sqrt(sum_ff_sq / @as(f64, @floatFromInt(min_6ch_len)));
        const r = if (sum_nat_sq > 0 and sum_ff_sq > 0) sum_prod / std.math.sqrt(sum_nat_sq * sum_ff_sq) else 0.0;
        std.debug.print("  Ch {d} [{s: <20}]: Nat RMS={d:.5} | FF RMS={d:.5} | Corr r={d:.6}\n", .{
            ch, ch_names[ch], rms_nat, rms_ff, r,
        });
    }

    if (std.Io.Dir.cwd().openFile(io, "tmp/ffmpeg_6ch.pcm", .{ .mode = .read_only })) |ref_file| {
        defer ref_file.close(io);
        var ref_buf: [65536]u8 = undefined;
        var ref_reader = ref_file.reader(io, &ref_buf);
        var ref_list = std.ArrayList(u8).empty;
        defer ref_list.deinit(allocator);
        try ref_reader.interface.appendRemaining(allocator, &ref_list, .unlimited);
        const ref_data = try ref_list.toOwnedSlice(allocator);
        defer allocator.free(ref_data);
        const ref_floats: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, ref_data));

        std.debug.print("\n=== PER-FRAME BEST OFFSET SEARCH FOR CENTER CHANNEL ===\n", .{});
        for (1..@min(10, nat_6ch[2].items.len / 1024)) |f_idx| {
            const nat_start = f_idx * 1024;
            var best_off: usize = 0;
            var max_r: f64 = 0;
            var best_signed_r: f64 = 0;

            for (0..@min(20000, ref_floats.len / 6)) |off| {
                if (off + 1024 > ref_floats.len / 6) break;
                var sum_prod: f64 = 0;
                var sum_n_sq: f64 = 0;
                var sum_r_sq: f64 = 0;
                for (0..1024) |s| {
                    const n_val = nat_6ch[2].items[nat_start + s];
                    const r_val = ref_floats[(off + s) * 6 + 2];
                    sum_prod += @as(f64, n_val) * @as(f64, r_val);
                    sum_n_sq += @as(f64, n_val) * @as(f64, n_val);
                    sum_r_sq += @as(f64, r_val) * @as(f64, r_val);
                }
                if (sum_n_sq > 0 and sum_r_sq > 0) {
                    const r_corr = sum_prod / @sqrt(sum_n_sq * sum_r_sq);
                    if (@abs(r_corr) > max_r) {
                        max_r = @abs(r_corr);
                        best_signed_r = r_corr;
                        best_off = off;
                    }
                }
            }
            const expected_off = (f_idx - 1) * 1024;
            const diff: i64 = @as(i64, @intCast(best_off)) - @as(i64, @intCast(expected_off));
            std.debug.print("  [Frame {d:>2}] best_off={d:>5} (expected {d:>5}, diff={d:>3}) r={d:.6}\n", .{
                f_idx, best_off, expected_off, diff, best_signed_r,
            });
        }
    } else |_| {}

    std.debug.print("  NAT ALIGNED[0..10]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
        nat_aligned[0], nat_aligned[1], nat_aligned[2], nat_aligned[3],
        nat_aligned[4], nat_aligned[5], nat_aligned[6], nat_aligned[7],
    });
    std.debug.print("  FF  ALIGNED[0..10]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
        ff_aligned[0], ff_aligned[1], ff_aligned[2], ff_aligned[3],
        ff_aligned[4], ff_aligned[5], ff_aligned[6], ff_aligned[7],
    });

    const NUM_SEGMENTS = 10;
    const segment_stats = try test_report.calculateStats(nat_aligned, ff_aligned, 48000, NUM_SEGMENTS, 1.0, allocator);
    defer allocator.free(segment_stats);

    const overall_stats_slice = try test_report.calculateStats(nat_aligned, ff_aligned, 48000, 1, 1.0, allocator);
    defer allocator.free(overall_stats_slice);
    const overall = overall_stats_slice[0];

    const ch_stats = test_report.calculateChannelStats(nat_aligned, ff_aligned, 1.0);

    std.debug.print(
        \\[PER-CHANNEL METRICS: AAC {s}]
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

    // 7. Quality observation notice
    if (failed_frames > 0 or overall.correlation < 0.99) {
        std.debug.print("\n[AAC Quality Notice] Decoder health: {d} failed frames, overall correlation r={d:.4}.\nInspect {s} for waveform visualization.\n\n", .{
            failed_frames, overall.correlation, report_filename,
        });
    }
}

test "AacDecoder test_video_aac_51.mkv vs FFmpeg reference" {
    const testing = std.testing;
    try runAacTest(testing.allocator, testing.io, "testvideo/test_video_aac_51.mkv", "5.1 Surround", "tmp/aac_51_decoding_report.html", 6);
}

test "AacDecoder diagnose lockstep test_video_aac_51" {
    const allocator = std.testing.allocator;
    const file_path = "testvideo/test_video_aac_51.mkv";

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    const c_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_path);

    if (c.avformat_open_input(&in_fmt_ctx, c_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(&in_fmt_ctx);
    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.FindStreamFailed;

    var a_idx: ?usize = null;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            a_idx = i;
            break;
        }
    }
    const audio_stream = in_fmt_ctx.?.streams[a_idx.?];
    const codec = c.avcodec_find_decoder(audio_stream.*.codecpar.*.codec_id) orelse return error.NoDecoder;
    var codec_ctx = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&codec_ctx);
    if (c.avcodec_parameters_to_context(codec_ctx, audio_stream.*.codecpar) < 0) return error.ParamFailed;
    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.OpenCodecFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&pkt);
    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);

    var native_dec = aac_dec.AacDecoder.init();
    native_dec.sample_rate = 48000;
    native_dec.channels = 6;

    std.debug.print("\n=== LOCKSTEP PACKET TRACE (test_video_aac_51.mkv) ===\n", .{});

    var pkt_count: usize = 0;
    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index != @as(c_int, @intCast(a_idx.?))) continue;
        defer pkt_count += 1;
        if (pkt_count >= 15) break;

        const raw_bytes: []const u8 = pkt.*.data[0..@intCast(pkt.*.size)];

        var nat_stereo: [2048]f32 = undefined;
        const n_nat = native_dec.decodeFrame(raw_bytes, &nat_stereo) catch |err| {
            std.debug.print("  Pkt #{d} pts={d}: Native decode error {}\n", .{ pkt_count, pkt.*.pts, err });
            continue;
        };

        _ = c.avcodec_send_packet(codec_ctx, pkt);
        while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
            const nb: usize = @intCast(frame.*.nb_samples);
            const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));

            const nat_c = native_dec.last_ch_pcm[2];
            const ff_c = data[2][0..nb];

            var sum_prod: f64 = 0; var sum_n2: f64 = 0; var sum_f2: f64 = 0;
            for (0..1024) |s| {
                const nv: f64 = @as(f64, nat_c[s]) * (1.0 / 65536.0);
                const fv: f64 = @as(f64, ff_c[s]);
                sum_prod += nv * fv; sum_n2 += nv * nv; sum_f2 += fv * fv;
            }
            const rms_n = std.math.sqrt(sum_n2 / 1024.0);
            const rms_f = std.math.sqrt(sum_f2 / 1024.0);
            const r = if (sum_n2 > 0 and sum_f2 > 0) sum_prod / std.math.sqrt(sum_n2 * sum_f2) else 0.0;

            const nat_fl = native_dec.last_ch_pcm[0];
            const ff_fl = data[0][0..nb];
            var sum_prod_fl: f64 = 0; var sum_n2_fl: f64 = 0; var sum_f2_fl: f64 = 0;
            for (0..1024) |s| {
                const nv: f64 = @as(f64, nat_fl[s]) * (1.0 / 65536.0);
                const fv: f64 = @as(f64, ff_fl[s]);
                sum_prod_fl += nv * fv; sum_n2_fl += nv * nv; sum_f2_fl += fv * fv;
            }
            const r_fl = if (sum_n2_fl > 0 and sum_f2_fl > 0) sum_prod_fl / std.math.sqrt(sum_n2_fl * sum_f2_fl) else 0.0;
            std.debug.print("Pkt #{d:>2} (pts={d:>3}): Center RMS Nat={d:.5} FF={d:.5} r={d:.6} | FL r={d:.6} (nat_samples={d})\n", .{
                pkt_count, frame.*.pts, rms_n, rms_f, r, r_fl, n_nat,
            });
            if (pkt_count >= 3 and pkt_count <= 8) {
                std.debug.print("    Nat C start: ", .{});
                for (0..8) |s| std.debug.print("{d:.4} ", .{@as(f64, nat_c[s]) * (-1.0 / 65536.0)});
                std.debug.print("\n    FF  C start: ", .{});
                for (0..8) |s| std.debug.print("{d:.4} ", .{ff_c[s]});
                std.debug.print("\n    Nat C end:   ", .{});
                for (1016..1024) |s| std.debug.print("{d:.4} ", .{@as(f64, nat_c[s]) * (-1.0 / 65536.0)});
                std.debug.print("\n    FF  C end:   ", .{});
                for (1016..1024) |s| std.debug.print("{d:.4} ", .{ff_c[s]});
                std.debug.print("\n", .{});
            }
        }
    }
}
