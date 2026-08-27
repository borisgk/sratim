const std = @import("std");
const isobmff = @import("isobmff.zig");
const fmp4_muxer = @import("fmp4_muxer.zig");
const streamer = @import("../streamer.zig");
const transcoder_mod = @import("../transcoder.zig");
const track_parser = @import("mkv/track_parser.zig");

/// Slices an existing MP4 file into a byte-compatible fMP4 stream starting at the nearest keyframe.
pub fn streamMp4(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    start_time: f64,
    audio_idx_requested: c_int,
    http_ctx: *streamer.HttpStreamContext,
) !void {
    var media = try isobmff.parseMp4Media(allocator, io, file_path);
    defer media.deinit(allocator);

    const video_track = media.video_track orelse return error.NoVideoTrackFound;
    if (video_track.samples.len == 0) return error.NoVideoSamplesFound;

    // Select audio track
    var selected_audio_track: ?isobmff.Mp4MediaTrack = null;
    if (media.audio_tracks.len > 0) {
        if (audio_idx_requested >= 0) {
            for (media.audio_tracks) |at| {
                if (@as(c_int, @intCast(at.stream_idx)) == audio_idx_requested) {
                    selected_audio_track = at;
                    break;
                }
            }
        }
        if (selected_audio_track == null) {
            selected_audio_track = media.audio_tracks[0];
        }
    }

    // 1. Check if audio transcoding is required
    var needs_audio_transcode = false;
    var audio_fourcc: [4]u8 = "mp4a".*;
    var audio_channels: u16 = 2;

    if (selected_audio_track) |at| {
        if (at.stsd_raw.len >= 24) {
            audio_fourcc = at.stsd_raw[20..24].*;
            if (at.stsd_raw.len >= 34) {
                audio_channels = std.mem.readInt(u16, at.stsd_raw[32..34], .big);
            }
        }
        if (!std.mem.eql(u8, &audio_fourcc, "mp4a") or audio_channels > 2) {
            needs_audio_transcode = true;
        }
    }

    var audio_transcoder: ?*transcoder_mod.StreamAudioTranscoder = null;
    defer if (audio_transcoder) |atc| atc.deinit();

    var synthetic_aac_stsd: ?[]u8 = null;
    defer if (synthetic_aac_stsd) |s| allocator.free(s);

    var mux_audio_track_opt: ?isobmff.Mp4MediaTrack = selected_audio_track;

    if (selected_audio_track) |at| {
        if (needs_audio_transcode) {
            std.debug.print("[Streamer] [MP4 Slicer] Video: native zero-copy | Audio: inline decode ({s}, {d}ch) -> Pure Zig AAC-LC encoding\n", .{ &audio_fourcc, audio_channels });
            audio_transcoder = try transcoder_mod.StreamAudioTranscoder.initFromCodec(
                &audio_fourcc,
                null,
                audio_channels,
                at.timescale,
            );
            synthetic_aac_stsd = try track_parser.buildAacStsd(allocator, &[_]u8{ 0x11, 0x90 }, 2, 48000);
            mux_audio_track_opt = isobmff.Mp4MediaTrack{
                .track_id = at.track_id,
                .stream_idx = at.stream_idx,
                .handler_type = at.handler_type,
                .timescale = 48000,
                .duration = 0,
                .stsd_raw = synthetic_aac_stsd.?,
                .samples = &.{},
                .sync_sample_indices = &.{},
            };
        } else {
            std.debug.print("[Streamer] [MP4 Slicer] 100% Pure Zig native stream (Video + Stereo AAC passthrough)\n", .{});
        }
    } else {
        std.debug.print("[Streamer] [MP4 Slicer] 100% Pure Zig native stream (Video only, no audio track)\n", .{});
    }

    // 2. Resolve seek keyframe for video
    var start_v_idx: usize = 0;
    if (start_time > 0.0) {
        var best_v_idx: usize = 0;
        for (video_track.samples, 0..) |s, idx| {
            if (s.is_sync) {
                if (s.pts_sec <= start_time) {
                    best_v_idx = idx;
                } else {
                    break;
                }
            }
        }
        start_v_idx = best_v_idx;
    }

    const seek_base_video_dts = video_track.samples[start_v_idx].dts;
    const seek_base_video_pts_sec = video_track.samples[start_v_idx].pts_sec;

    // 3. Resolve seek start sample for audio
    var start_a_idx: usize = 0;
    var seek_base_audio_dts: u64 = 0;

    if (selected_audio_track) |at| {
        if (at.samples.len > 0 and start_time > 0.0) {
            var best_a_idx: usize = 0;
            for (at.samples, 0..) |s, idx| {
                if (s.pts_sec <= seek_base_video_pts_sec) {
                    best_a_idx = idx;
                } else {
                    break;
                }
            }
            start_a_idx = best_a_idx;
            seek_base_audio_dts = at.samples[start_a_idx].dts;
        }
    }

    // 4. Write Initialization Segment (ftyp + moov)
    const init_segment = try fmp4_muxer.buildInitSegment(allocator, video_track, mux_audio_track_opt);
    defer allocator.free(init_segment);

    http_ctx.writer.writer.writeAll(init_segment) catch {
        http_ctx.has_error = true;
        return;
    };

    // Open file for streaming sample payloads
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var transfer_buf: [65536]u8 = undefined;
    var raw_audio_buf = std.ArrayList(u8).empty;
    defer raw_audio_buf.deinit(allocator);

    var transcoded_audio_frames = std.ArrayList(transcoder_mod.EncodedAacFrame).empty;
    defer {
        for (transcoded_audio_frames.items) |f| allocator.free(f.data);
        transcoded_audio_frames.deinit(allocator);
    }

    var seq_num: u32 = 1;
    var current_v_idx = start_v_idx;
    var current_a_idx = start_a_idx;
    var running_transcoded_audio_samples: u64 = 0;

    // 5. Stream Fragments (One fragment per video GOP)
    while (current_v_idx < video_track.samples.len) {
        if (http_ctx.has_error) break;

        // Determine video GOP end index
        var v_end = current_v_idx + 1;
        while (v_end < video_track.samples.len) {
            if (video_track.samples[v_end].is_sync) break;
            v_end += 1;
        }

        const v_slice = video_track.samples[current_v_idx..v_end];
        const frag_end_pts_sec = if (v_end < video_track.samples.len)
            video_track.samples[v_end].pts_sec
        else
            video_track.samples[v_end - 1].pts_sec + 2.0;

        // Determine matching audio slice
        var a_end = current_a_idx;
        if (selected_audio_track) |at| {
            while (a_end < at.samples.len) {
                if (at.samples[a_end].pts_sec >= frag_end_pts_sec) break;
                a_end += 1;
            }
        }

        const a_slice: []const isobmff.MediaSample = if (selected_audio_track) |at|
            if (a_end > current_a_idx) at.samples[current_a_idx..a_end] else &.{}
        else
            &.{};

        // If audio transcoding, decode and encode all samples in this audio slice
        if (needs_audio_transcode and a_slice.len > 0) {
            for (a_slice) |s| {
                file_reader.seekTo(s.offset) catch {
                    http_ctx.has_error = true;
                    break;
                };
                raw_audio_buf.clearRetainingCapacity();
                try raw_audio_buf.resize(allocator, s.size);
                file_reader.interface.readSliceAll(raw_audio_buf.items) catch {
                    http_ctx.has_error = true;
                    break;
                };
                try audio_transcoder.?.transcodePacket(allocator, raw_audio_buf.items, &transcoded_audio_frames);
            }
        }

        var dynamic_a_samples = std.ArrayList(isobmff.MediaSample).empty;
        defer dynamic_a_samples.deinit(allocator);

        const out_a_slice: []const isobmff.MediaSample = if (needs_audio_transcode) blk: {
            for (transcoded_audio_frames.items) |f| {
                try dynamic_a_samples.append(allocator, isobmff.MediaSample{
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
            break :blk dynamic_a_samples.items;
        } else a_slice;

        // Calculate total payload byte sizes
        var total_v_bytes: usize = 0;
        for (v_slice) |s| total_v_bytes += s.size;

        var total_a_bytes: usize = 0;
        for (out_a_slice) |s| total_a_bytes += s.size;

        const base_video_dts = video_track.samples[current_v_idx].dts - seek_base_video_dts;
        const base_audio_dts = if (needs_audio_transcode)
            running_transcoded_audio_samples
        else if (a_slice.len > 0)
            a_slice[0].dts - seek_base_audio_dts
        else
            0;

        if (needs_audio_transcode) {
            running_transcoded_audio_samples += @as(u64, transcoded_audio_frames.items.len) * 1024;
        }

        // Build and write Fragment Header (moof + mdat header)
        const frag_hdr = try fmp4_muxer.buildFragmentHeader(
            allocator,
            seq_num,
            video_track,
            v_slice,
            base_video_dts,
            mux_audio_track_opt,
            out_a_slice,
            base_audio_dts,
            total_v_bytes,
            total_a_bytes,
        );
        defer allocator.free(frag_hdr);

        http_ctx.writer.writer.writeAll(frag_hdr) catch {
            http_ctx.has_error = true;
            break;
        };

        // Stream Video Samples
        for (v_slice) |s| {
            if (s.size == 0) continue;
            file_reader.seekTo(s.offset) catch {
                http_ctx.has_error = true;
                break;
            };

            var rem = s.size;
            while (rem > 0) {
                const to_read: usize = @intCast(@min(rem, transfer_buf.len));
                file_reader.interface.readSliceAll(transfer_buf[0..to_read]) catch {
                    http_ctx.has_error = true;
                    break;
                };
                http_ctx.writer.writer.writeAll(transfer_buf[0..to_read]) catch {
                    http_ctx.has_error = true;
                    break;
                };
                rem -= @intCast(to_read);
            }
            if (http_ctx.has_error) break;
        }

        // Stream Audio Samples
        if (!http_ctx.has_error and out_a_slice.len > 0) {
            if (needs_audio_transcode) {
                for (transcoded_audio_frames.items) |f| {
                    http_ctx.writer.writer.writeAll(f.data) catch {
                        http_ctx.has_error = true;
                        break;
                    };
                }
                for (transcoded_audio_frames.items) |f| allocator.free(f.data);
                transcoded_audio_frames.clearRetainingCapacity();
            } else {
                for (a_slice) |s| {
                    if (s.size == 0) continue;
                    file_reader.seekTo(s.offset) catch {
                        http_ctx.has_error = true;
                        break;
                    };

                    var rem = s.size;
                    while (rem > 0) {
                        const to_read: usize = @intCast(@min(rem, transfer_buf.len));
                        file_reader.interface.readSliceAll(transfer_buf[0..to_read]) catch {
                            http_ctx.has_error = true;
                            break;
                        };
                        http_ctx.writer.writer.writeAll(transfer_buf[0..to_read]) catch {
                            http_ctx.has_error = true;
                            break;
                        };
                        rem -= @intCast(to_read);
                    }
                    if (http_ctx.has_error) break;
                }
            }
        }

        seq_num += 1;
        current_v_idx = v_end;
        current_a_idx = a_end;

        std.Thread.yield() catch {};
    }
}

test "parseMp4Media and fMP4 init segment on test_subs.mp4" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const f = std.Io.Dir.cwd().openFile(io, "tests/test_subs.mp4", .{ .mode = .read_only }) catch return;
    f.close(io);

    var media = try isobmff.parseMp4Media(allocator, io, "tests/test_subs.mp4");
    defer media.deinit(allocator);

    try std.testing.expect(media.video_track != null);
    const vt = media.video_track.?;
    try std.testing.expect(vt.samples.len > 0);
    try std.testing.expect(vt.width > 0);
    try std.testing.expect(vt.height > 0);
    try std.testing.expect(vt.stsd_raw.len > 0);

    try std.testing.expect(media.audio_tracks.len > 0);
    const at = media.audio_tracks[0];
    try std.testing.expect(at.samples.len > 0);
    try std.testing.expect(at.stsd_raw.len > 0);

    // Test building init segment
    const init_seg = try fmp4_muxer.buildInitSegment(allocator, vt, at);
    defer allocator.free(init_seg);

    try std.testing.expect(std.mem.startsWith(u8, init_seg[4..8], "ftyp"));
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "moov") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_seg, "mvex") != null);
}
