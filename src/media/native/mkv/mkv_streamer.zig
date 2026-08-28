const std = @import("std");
const types = @import("types.zig");
const track_parser = @import("track_parser.zig");
const block_reader = @import("block_reader.zig");
const gop_builder = @import("gop_builder.zig");
const cues = @import("../cues.zig");
const isobmff = @import("../isobmff.zig");
const fmp4_muxer = @import("../fmp4_muxer.zig");
const streamer = @import("../../streamer.zig");
const transcoder_mod = @import("../../transcoder.zig");
const config_mod = @import("../../../config.zig");

const MkvTrackInfo = types.MkvTrackInfo;
const MkvBlock = types.MkvBlock;
const MediaSample = isobmff.MediaSample;
const BlockReader = block_reader.BlockReader;

/// Checks whether an MKV file can be remuxed and sliced natively (supported video + native or transcodable audio).
pub fn canStreamMkvNatively(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    audio_idx_requested: c_int,
) bool {
    const tracks = track_parser.parseMkvTracks(allocator, io, file_path) catch return false;
    defer {
        for (tracks) |*t| {
            var mut_t = t.*;
            mut_t.deinit(allocator);
        }
        allocator.free(tracks);
    }

    var has_supported_video = false;
    for (tracks) |t| {
        if (t.track_type == .Video) {
            if (std.mem.eql(u8, t.codec_id, "V_MPEG4/ISO/AVC") or std.mem.eql(u8, t.codec_id, "V_MPEGH/ISO/HEVC")) {
                has_supported_video = true;
                break;
            }
        }
    }
    if (!has_supported_video) return false;

    // Check if the requested or first audio track is playable directly or transcodable
    var audio_track_opt: ?*const MkvTrackInfo = null;
    if (audio_idx_requested >= 0) {
        const target_stream: usize = @intCast(audio_idx_requested);
        for (tracks) |*t| {
            if (t.track_type == .Audio and t.stream_idx == target_stream) {
                audio_track_opt = t;
                break;
            }
        }
    }
    if (audio_track_opt == null) {
        for (tracks) |*t| {
            if (t.track_type == .Audio) {
                audio_track_opt = t;
                break;
            }
        }
    }

    if (audio_track_opt) |at| {
        const is_native_aac = (at.stsd_raw != null and at.channels <= 2);
        const is_transcodable = (transcoder_mod.StreamAudioTranscoder.mapCodecId(at.codec_id) != null);
        if (!is_native_aac and !is_transcodable) return false;
    }

    return true;
}

/// Pure Zig pipeline to stream an MKV media file as fragmented MP4 starting at the nearest keyframe.
pub fn streamMkv(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    start_time: f64,
    audio_idx_requested: c_int,
    http_ctx: *streamer.HttpStreamContext,
    audio_transcoder_mode: config_mod.EngineMode,
) !void {
    return streamMkvGeneric(allocator, io, file_path, start_time, audio_idx_requested, &http_ctx.writer.writer, &http_ctx.has_error, null, audio_transcoder_mode);
}

pub fn streamMkvGeneric(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    start_time: f64,
    audio_idx_requested: c_int,
    writer: *std.Io.Writer,
    has_error: *bool,
    max_fragments: ?usize,
    audio_transcoder_mode: config_mod.EngineMode,
) !void {
    const tracks = try track_parser.parseMkvTracks(allocator, io, file_path);
    defer {
        for (tracks) |*t| {
            var mut_t = t.*;
            mut_t.deinit(allocator);
        }
        allocator.free(tracks);
    }

    // 1. Identify video and audio tracks
    var video_track_opt: ?*const MkvTrackInfo = null;
    var audio_track_opt: ?*const MkvTrackInfo = null;

    for (tracks) |*t| {
        if (t.track_type == .Video and video_track_opt == null) {
            if (std.mem.eql(u8, t.codec_id, "V_MPEG4/ISO/AVC") or std.mem.eql(u8, t.codec_id, "V_MPEGH/ISO/HEVC")) {
                video_track_opt = t;
            }
        }
    }
    const video_trk = video_track_opt orelse return error.NoSupportedVideoTrack;
    const video_stsd = video_trk.stsd_raw orelse return error.NoStsdHeader;

    if (audio_idx_requested >= 0) {
        const target_stream: usize = @intCast(audio_idx_requested);
        for (tracks) |*t| {
            if (t.track_type == .Audio and t.stream_idx == target_stream) {
                audio_track_opt = t;
                break;
            }
        }
    }
    if (audio_track_opt == null) {
        for (tracks) |*t| {
            if (t.track_type == .Audio) {
                audio_track_opt = t;
                break;
            }
        }
    }

    // Resolve seek offset using Cues table
    var tv_start: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv_start, null);
    const start_wall_time = @as(i64, tv_start.sec) * 1000 + @divTrunc(tv_start.usec, 1000);
    var seek_cluster_offset: u64 = 0;
    var seek_keyframe_pts_sec: f64 = 0.0;

    if (start_time > 0.0) {
        if (cues.findCueSeekPosition(io, file_path, start_time) catch null) |seek_res| {
            seek_cluster_offset = seek_res.cluster_offset;
            seek_keyframe_pts_sec = seek_res.pts_sec;
        }
    }

    // 2. Setup Audio Transcoder if needed
    const needs_audio_transcode = if (audio_track_opt) |at|
        (at.stsd_raw == null or at.channels > 2)
    else
        false;

    var audio_transcoder: ?*transcoder_mod.StreamAudioTranscoder = null;
    defer if (audio_transcoder) |atc| atc.deinit();

    var synthetic_aac_stsd: ?[]u8 = null;
    defer if (synthetic_aac_stsd) |s| allocator.free(s);

    if (needs_audio_transcode) {
        const at = audio_track_opt.?;
        const use_native_enc = (audio_transcoder_mode == .native);
        var audio_desc_buf: [128]u8 = undefined;
        const audio_desc = if (use_native_enc)
            (if (std.mem.eql(u8, at.codec_id, "A_AC3"))
                std.fmt.bufPrint(&audio_desc_buf, "Pure Zig AC-3 ({d}ch) -> Pure Zig AAC-LC", .{at.channels})
            else
                std.fmt.bufPrint(&audio_desc_buf, "Inline decode ({s}, {d}ch) -> Pure Zig AAC-LC", .{ at.codec_id, at.channels })) catch "Inline decode -> Pure Zig AAC-LC"
        else
            std.fmt.bufPrint(&audio_desc_buf, "Inline FFmpeg ({s}, {d}ch -> Stereo AAC)", .{ at.codec_id, at.channels }) catch "Inline FFmpeg";
        streamer.logStreamStatus(file_path, audio_idx_requested, "Native MKV Slicer", "Zero-copy passthrough", audio_desc);

        audio_transcoder = try transcoder_mod.StreamAudioTranscoder.initFromCodec(
            at.codec_id,
            at.codec_private,
            at.channels,
            at.sample_rate,
            use_native_enc,
        );
        synthetic_aac_stsd = try track_parser.buildAacStsd(allocator, &[_]u8{ 0x11, 0x90 }, 2, 48000);
    } else if (audio_track_opt != null) {
        streamer.logStreamStatus(file_path, audio_idx_requested, "Native MKV Slicer", "Zero-copy passthrough", "Zero-copy passthrough (Stereo AAC)");
    } else {
        streamer.logStreamStatus(file_path, audio_idx_requested, "Native MKV Slicer", "Zero-copy passthrough", "None (no audio track)");
    }

    // 3. Build initialization segment (ftyp + moov)
    const video_mp4_track = isobmff.Mp4MediaTrack{
        .track_id = 1,
        .stream_idx = video_trk.stream_idx,
        .handler_type = "vide".*,
        .timescale = 1000,
        .duration = 0,
        .width = video_trk.width,
        .height = video_trk.height,
        .stsd_raw = video_stsd,
        .samples = &.{},
        .sync_sample_indices = &.{},
    };

    var audio_mp4_track_opt: ?isobmff.Mp4MediaTrack = null;
    var audio_timescale: u32 = 48000;
    if (audio_track_opt) |at| {
        const astsd = if (needs_audio_transcode) synthetic_aac_stsd.? else at.stsd_raw.?;
        audio_timescale = if (!needs_audio_transcode and at.sample_rate > 0) at.sample_rate else 48000;
        audio_mp4_track_opt = isobmff.Mp4MediaTrack{
            .track_id = 2,
            .stream_idx = at.stream_idx,
            .handler_type = "soun".*,
            .timescale = audio_timescale,
            .duration = 0,
            .stsd_raw = astsd,
            .samples = &.{},
            .sync_sample_indices = &.{},
        };
    }

    const init_segment = try fmp4_muxer.buildInitSegment(allocator, video_mp4_track, audio_mp4_track_opt);
    defer allocator.free(init_segment);

    writer.writeAll(init_segment) catch {
        has_error.* = true;
        return;
    };

    // 4. Open separate file handles: one for sequential demuxing, one for payload streaming
    const demux_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    if (seek_cluster_offset > 0) {
        demux_reader.seekTo(seek_cluster_offset) catch {};
    }

    var block_rdr = BlockReader.init(&demux_reader.interface, 1_000_000);
    var current_file_pos = seek_cluster_offset;

    var transfer_buf: [65536]u8 = undefined;
    var seq_num: u32 = 1;

    var seek_base_video_dts: ?u64 = null;
    var running_audio_samples: u64 = 0;

    var pending_video_blocks = std.ArrayList(MkvBlock).empty;
    defer pending_video_blocks.deinit(allocator);

    var pending_audio_blocks = std.ArrayList(MkvBlock).empty;
    defer pending_audio_blocks.deinit(allocator);

    var transcoded_audio_frames = std.ArrayList(transcoder_mod.EncodedAacFrame).empty;
    defer {
        for (transcoded_audio_frames.items) |f| allocator.free(f.data);
        transcoded_audio_frames.deinit(allocator);
    }

    var raw_audio_packet_buf = std.ArrayList(u8).empty;
    defer raw_audio_packet_buf.deinit(allocator);

    var next_gop_keyframe: ?MkvBlock = null;

    // 5. Stream GOP fragments
    while (!has_error.*) {
        if (max_fragments) |max_f| {
            if (seq_num > max_f) break;
        }

        pending_video_blocks.clearRetainingCapacity();
        pending_audio_blocks.clearRetainingCapacity();

        if (next_gop_keyframe) |kf| {
            try pending_video_blocks.append(allocator, kf);
            next_gop_keyframe = null;
        }

        // Collect blocks until the next video keyframe or EOF
        while (true) {
            const blk = (try block_rdr.readNextBlock(&current_file_pos)) orelse break;

            if (blk.track_num == video_trk.track_num) {
                if (pending_video_blocks.items.len == 0) {
                    // First block of stream MUST be a keyframe
                    if (!blk.is_keyframe) continue;
                } else if (blk.is_keyframe) {
                    // Next GOP keyframe reached
                    next_gop_keyframe = blk;
                    break;
                }
                try pending_video_blocks.append(allocator, blk);
            } else if (audio_track_opt != null and blk.track_num == audio_track_opt.?.track_num) {
                // Do not accumulate audio preceding the first video keyframe on seek
                if (pending_video_blocks.items.len == 0) continue;
                if (seq_num == 1) {
                    const kf_pts = pending_video_blocks.items[0].pts_ms;
                    if (blk.pts_ms + 25 < kf_pts) continue;
                }

                if (needs_audio_transcode) {
                    payload_reader.seekTo(blk.payload_offset) catch {
                        has_error.* = true;
                        break;
                    };
                    raw_audio_packet_buf.clearRetainingCapacity();
                    try raw_audio_packet_buf.resize(allocator, blk.payload_size);
                    payload_reader.interface.readSliceAll(raw_audio_packet_buf.items) catch {
                        has_error.* = true;
                        break;
                    };
                    try audio_transcoder.?.transcodePacket(allocator, raw_audio_packet_buf.items, &transcoded_audio_frames);
                } else {
                    try pending_audio_blocks.append(allocator, blk);
                }
            }
        }

        if (pending_video_blocks.items.len == 0) break; // EOF reached

        // Resolve GOP video samples (DTS, PTS, CTTS)
        const v_samples = try gop_builder.buildGopMediaSamples(allocator, pending_video_blocks.items, 1000, 33);
        defer allocator.free(v_samples);

        if (seek_base_video_dts == null) {
            seek_base_video_dts = v_samples[0].dts;
        }

        // Build audio media samples
        var a_samples = std.ArrayList(MediaSample).empty;
        defer a_samples.deinit(allocator);

        if (audio_mp4_track_opt != null) {
            if (needs_audio_transcode) {
                for (transcoded_audio_frames.items) |f| {
                    try a_samples.append(allocator, MediaSample{
                        .dts_delta = f.sample_count,
                        .dts = 0,
                        .pts = 0,
                        .pts_sec = 0,
                        .offset = 0,
                        .size = @intCast(f.data.len),
                        .is_sync = true,
                        .ctts_offset = 0,
                    });
                }
            } else if (pending_audio_blocks.items.len > 0) {
                for (pending_audio_blocks.items) |ab| {
                    try a_samples.append(allocator, MediaSample{
                        .dts_delta = 1024,
                        .dts = 0,
                        .pts = 0,
                        .pts_sec = ab.pts_sec,
                        .offset = ab.payload_offset,
                        .size = ab.payload_size,
                        .is_sync = true,
                        .ctts_offset = 0,
                    });
                }
            }
        }

        var total_v_bytes: usize = 0;
        for (v_samples) |s| total_v_bytes += s.size;

        var total_a_bytes: usize = 0;
        for (a_samples.items) |s| total_a_bytes += s.size;

        const base_video_dts = v_samples[0].dts - seek_base_video_dts.?;
        const base_audio_dts = running_audio_samples;
        running_audio_samples += @as(u64, a_samples.items.len) * 1024;

        if (seq_num == 1) {
            var tv_now: std.c.timeval = undefined;
            _ = std.c.gettimeofday(&tv_now, null);
            const now_ms = @as(i64, tv_now.sec) * 1000 + @divTrunc(tv_now.usec, 1000);
            std.debug.print("[TIMING] Frag 1 generated in {} ms (V_bytes={}, A_bytes={})\n", .{
                now_ms - start_wall_time,
                total_v_bytes,
                total_a_bytes,
            });
        }

        // Build and write Fragment Header (moof + mdat header)
        const frag_hdr = try fmp4_muxer.buildFragmentHeader(
            allocator,
            seq_num,
            video_mp4_track,
            v_samples,
            base_video_dts,
            audio_mp4_track_opt,
            a_samples.items,
            base_audio_dts,
            total_v_bytes,
            total_a_bytes,
        );
        defer allocator.free(frag_hdr);

        writer.writeAll(frag_hdr) catch {
            has_error.* = true;
            break;
        };

        // Stream video payload bytes directly from payload_file
        for (v_samples) |s| {
            if (s.size == 0) continue;
            payload_reader.seekTo(s.offset) catch {
                has_error.* = true;
                break;
            };

            var rem = s.size;
            while (rem > 0) {
                const to_read: usize = @intCast(@min(rem, transfer_buf.len));
                payload_reader.interface.readSliceAll(transfer_buf[0..to_read]) catch {
                    has_error.* = true;
                    break;
                };
                writer.writeAll(transfer_buf[0..to_read]) catch {
                    has_error.* = true;
                    break;
                };
                rem -= @intCast(to_read);
            }
            if (has_error.*) break;
        }

        // Stream audio payload bytes
        if (!has_error.* and a_samples.items.len > 0) {
            if (needs_audio_transcode) {
                for (transcoded_audio_frames.items) |f| {
                    writer.writeAll(f.data) catch {
                        has_error.* = true;
                        break;
                    };
                }
                for (transcoded_audio_frames.items) |f| allocator.free(f.data);
                transcoded_audio_frames.clearRetainingCapacity();
            } else {
                for (a_samples.items) |s| {
                    if (s.size == 0) continue;
                    payload_reader.seekTo(s.offset) catch {
                        has_error.* = true;
                        break;
                    };

                    var rem = s.size;
                    while (rem > 0) {
                        const to_read: usize = @intCast(@min(rem, transfer_buf.len));
                        payload_reader.interface.readSliceAll(transfer_buf[0..to_read]) catch {
                            has_error.* = true;
                            break;
                        };
                        writer.writeAll(transfer_buf[0..to_read]) catch {
                            has_error.* = true;
                            break;
                        };
                        rem -= @intCast(to_read);
                    }
                    if (has_error.*) break;
                }
            }
        }

        seq_num += 1;
        std.Thread.yield() catch {};
    }
}

test "generate MKV fMP4 fragments for Sof Ha Olam Smola" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Sof Ha Olam Smola (2004).mkv",
        0.0,
        2, // Hebrew AAC track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "generate MKV fMP4 fragments with AC3 audio transcoding" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_ac3_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    // Track 1 of Sof Ha Olam Smola is AC3 (Russian)
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Sof Ha Olam Smola (2004).mkv",
        0.0,
        1, // Russian AC3 track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "generate MKV fMP4 fragments for Tuner.mkv with 5.1 AAC downmixing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_tuner_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Tuner.mkv",
        0.0,
        1, // 5.1 AAC track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "generate MKV fMP4 fragments for Along Came Polly with AC3 5.1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_polly_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Along Came Polly (2004).mkv",
        0.0,
        1, // AC3 5.1 track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "generate MKV fMP4 fragments for Night at the Museum with DTS 5.1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_dts_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Ночь в музее_Секрет гробницы.1080p. Ton.mkv",
        0.0,
        1, // DTS 5.1 track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "generate MKV fMP4 fragments for Fiddler on the Roof with AC3 2.0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_fiddler_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Fiddler.on.the.Roof.1971.1080p.BluRay.x264-DiVULGED.mkv",
        0.0,
        2, // AC3 2.0 commentary track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "compare seek in Sof Ha Olam Smola AAC vs AC3" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const file_path = "/Users/borisk/Movies/Sratim/Movies/Sof Ha Olam Smola (2004).mkv";

    const seek_res = cues.findCueSeekPosition(io, file_path, 60.0) catch return;
    _ = seek_res;

    // Track 2: AAC (passthrough)
    {
        const out_file = std.Io.Dir.cwd().createFile(io, "tmp/seek_sof_aac.mp4", .{}) catch return;
        defer out_file.close(io);
        var out_buf: [65536]u8 = undefined;
        var out_writer = out_file.writer(io, &out_buf);
        var has_error = false;
        try streamMkvGeneric(allocator, io, file_path, 60.0, 2, &out_writer.interface, &has_error, 2, .native);
        try out_writer.flush();
    }

    // Track 1: AC3 (transcode)
    {
        const out_file = std.Io.Dir.cwd().createFile(io, "tmp/seek_sof_ac3.mp4", .{}) catch return;
        defer out_file.close(io);
        var out_buf: [65536]u8 = undefined;
        var out_writer = out_file.writer(io, &out_buf);
        var has_error = false;
        try streamMkvGeneric(allocator, io, file_path, 60.0, 1, &out_writer.interface, &has_error, 2, .native);
        try out_writer.flush();
    }
}

