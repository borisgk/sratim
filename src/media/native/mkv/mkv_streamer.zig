const std = @import("std");
const types = @import("types.zig");
const track_parser = @import("track_parser.zig");
const block_reader = @import("block_reader.zig");
const gop_builder = @import("gop_builder.zig");
const cues = @import("../cues.zig");
const isobmff = @import("../isobmff.zig");
const fmp4_muxer = @import("../fmp4_muxer.zig");
const streamer = @import("../../streamer.zig");

const MkvTrackInfo = types.MkvTrackInfo;
const MkvBlock = types.MkvBlock;
const MediaSample = isobmff.MediaSample;
const BlockReader = block_reader.BlockReader;

/// Checks whether an MKV file can be remuxed and sliced natively (supported video + AAC audio).
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

    var video_track_opt: ?MkvTrackInfo = null;
    var audio_track_opt: ?MkvTrackInfo = null;

    for (tracks) |t| {
        if (t.track_type == .Video and video_track_opt == null) {
            video_track_opt = t;
        } else if (t.track_type == .Audio) {
            if (audio_idx_requested >= 0) {
                if (@as(c_int, @intCast(t.stream_idx)) == audio_idx_requested) {
                    audio_track_opt = t;
                }
            } else if (audio_track_opt == null) {
                audio_track_opt = t;
            }
        }
    }

    const video_trk = video_track_opt orelse return false;
    if (video_trk.stsd_raw == null) return false;

    if (audio_track_opt) |at| {
        // Only 2-channel (stereo) or mono AAC can be played natively without downmixing
        if (at.stsd_raw == null or at.channels > 2) return false;
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
) !void {
    return streamMkvGeneric(allocator, io, file_path, start_time, audio_idx_requested, &http_ctx.writer.writer, &http_ctx.has_error, null);
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
) !void {
    const tracks = try track_parser.parseMkvTracks(allocator, io, file_path);
    defer {
        for (tracks) |*t| {
            var mut_t = t.*;
            mut_t.deinit(allocator);
        }
        allocator.free(tracks);
    }

    var video_track_opt: ?MkvTrackInfo = null;
    var audio_track_opt: ?MkvTrackInfo = null;

    for (tracks) |t| {
        if (t.track_type == .Video and video_track_opt == null) {
            video_track_opt = t;
        } else if (t.track_type == .Audio) {
            if (audio_idx_requested >= 0) {
                if (@as(c_int, @intCast(t.stream_idx)) == audio_idx_requested) {
                    audio_track_opt = t;
                }
            } else if (audio_track_opt == null) {
                audio_track_opt = t;
            }
        }
    }

    const video_trk = video_track_opt orelse return error.NoVideoTrackFound;
    const video_stsd = video_trk.stsd_raw orelse return error.UnsupportedVideoCodec;

    // 1. Resolve seek offset using Cues table
    var seek_cluster_offset: u64 = 0;
    var seek_keyframe_pts_sec: f64 = 0.0;

    if (start_time > 0.0) {
        if (cues.findCueSeekPosition(io, file_path, start_time) catch null) |seek_res| {
            seek_cluster_offset = seek_res.cluster_offset;
            seek_keyframe_pts_sec = seek_res.pts_sec;
        }
    }

    // 2. Build initialization segment (ftyp + moov)
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
        if (at.stsd_raw) |astsd| {
            audio_timescale = if (at.sample_rate > 0) at.sample_rate else 48000;
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
    }

    const init_segment = try fmp4_muxer.buildInitSegment(allocator, video_mp4_track, audio_mp4_track_opt);
    defer allocator.free(init_segment);

    writer.writeAll(init_segment) catch {
        has_error.* = true;
        return;
    };

    // 3. Open separate file handles: one for sequential demuxing, one for payload streaming
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

    var next_gop_keyframe: ?MkvBlock = null;

    // 4. Stream GOP fragments
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
                if (blk.is_keyframe and pending_video_blocks.items.len > 0) {
                    // Next GOP keyframe reached
                    next_gop_keyframe = blk;
                    break;
                }
                try pending_video_blocks.append(allocator, blk);
            } else if (audio_track_opt != null and blk.track_num == audio_track_opt.?.track_num) {
                try pending_audio_blocks.append(allocator, blk);
            }
        }

        if (pending_video_blocks.items.len == 0) break; // EOF reached

        // Resolve GOP video samples (DTS, PTS, CTTS)
        const v_samples = try gop_builder.buildGopMediaSamples(allocator, pending_video_blocks.items, 1000, 33);
        defer allocator.free(v_samples);

        if (seek_base_video_dts == null) {
            seek_base_video_dts = v_samples[0].dts;
        }

        // Build audio media samples (strictly 1024 samples per AAC frame)
        var a_samples = std.ArrayList(MediaSample).empty;
        defer a_samples.deinit(allocator);

        if (audio_mp4_track_opt != null and pending_audio_blocks.items.len > 0) {
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

        var total_v_bytes: usize = 0;
        for (v_samples) |s| total_v_bytes += s.size;

        var total_a_bytes: usize = 0;
        for (a_samples.items) |s| total_a_bytes += s.size;

        const base_video_dts = v_samples[0].dts - seek_base_video_dts.?;
        const base_audio_dts = running_audio_samples;
        running_audio_samples += @as(u64, a_samples.items.len) * 1024;

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

        // Stream audio payload bytes directly from payload_file
        if (!has_error.* and a_samples.items.len > 0) {
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
    );
    try out_writer.flush();
}
