const std = @import("std");
const ebml = @import("ebml.zig");
const mp4_muxer = @import("mp4_muxer.zig");
const native_metadata = @import("metadata.zig");

pub const StreamContext = struct {
    writer: *std.http.BodyWriter,
    has_error: bool = false,
};

pub const TrackInfo = struct {
    track_num: u64,
    track_type: u64, // 1 = Video, 2 = Audio
    codec_id: []const u8,
    codec_private: ?[]const u8 = null,
    width: u32 = 0,
    height: u32 = 0,
    sample_rate: u32 = 48000,
    channels: u16 = 2,
};

/// Normalizes NAL units to 4-byte big-endian size prefix (AVCC/HVCC format).
pub fn appendNalUnits(allocator: std.mem.Allocator, payload: *std.ArrayList(u8), raw_data: []const u8) !void {
    if (raw_data.len < 4) {
        try payload.appendSlice(allocator, raw_data);
        return;
    }

    const is_annex_b_4 = (raw_data[0] == 0 and raw_data[1] == 0 and raw_data[2] == 0 and raw_data[3] == 1);
    const is_annex_b_3 = (raw_data[0] == 0 and raw_data[1] == 0 and raw_data[2] == 1);

    if (is_annex_b_4 or is_annex_b_3) {
        var offset: usize = if (is_annex_b_4) 4 else 3;
        while (offset < raw_data.len) {
            const nalu_start = offset;
            var next_start = raw_data.len;
            var next_prefix_len: usize = 0;

            var i = offset;
            while (i + 3 <= raw_data.len) : (i += 1) {
                if (raw_data[i] == 0 and raw_data[i + 1] == 0) {
                    if (raw_data[i + 2] == 1) {
                        next_start = i;
                        next_prefix_len = 3;
                        break;
                    } else if (i + 4 <= raw_data.len and raw_data[i + 2] == 0 and raw_data[i + 3] == 1) {
                        next_start = i;
                        next_prefix_len = 4;
                        break;
                    }
                }
            }

            const nalu_len: u32 = @intCast(next_start - nalu_start);
            if (nalu_len > 0) {
                var len_b: [4]u8 = undefined;
                std.mem.writeInt(u32, &len_b, nalu_len, .big);
                try payload.appendSlice(allocator, &len_b);
                try payload.appendSlice(allocator, raw_data[nalu_start..next_start]);
            }

            offset = next_start + next_prefix_len;
        }
    } else {
        // Already AVCC/HVCC length-prefixed
        try payload.appendSlice(allocator, raw_data);
    }
}

/// Pure Zig MKV Demuxer and Fragmented MP4 (fMP4) live streaming pipeline.
pub fn streamMediaNative(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    start_time: f64,
    audio_idx_requested: c_int,
    writer: *std.http.BodyWriter,
) !void {
    _ = audio_idx_requested;
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    const ebml_hdr = (try ebml.readElementHeader(r)) orelse return error.InvalidEbml;
    if (ebml_hdr.id != ebml.ID_EBML) return error.NotMatroska;
    try ebml.skipBytes(r, ebml_hdr.size);

    const seg_hdr = (try ebml.readElementHeader(r)) orelse return error.InvalidEbml;
    if (seg_hdr.id != ebml.ID_SEGMENT) return error.NotMatroska;

    const segment_data_pos = file_reader.logicalPos();
    var timestamp_scale: f64 = 1_000_000.0;
    var cues_pos: ?u64 = null;
    var first_cluster_pos: ?u64 = null;

    var video_track_opt: ?TrackInfo = null;
    var audio_track_opt: ?TrackInfo = null;

    var tracks_arena = std.heap.ArenaAllocator.init(allocator);
    defer tracks_arena.deinit();
    const arena = tracks_arena.allocator();

    // 1. Scan Segment headers (SeekHead, Info, Tracks)
    while (true) {
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_SEEK_HEAD) {
            var seek_head_rem = elem.size;
            while (seek_head_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                seek_head_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > seek_head_rem) break;

                if (sub.id == ebml.ID_SEEK) {
                    var seek_rem = sub.size;
                    var seek_id: ?u64 = null;
                    var seek_pos: ?u64 = null;

                    while (seek_rem > 0) {
                        const child = (try ebml.readElementHeader(r)) orelse break;
                        seek_rem -= child.header_size;
                        if (child.size != ebml.UNKNOWN_SIZE and child.size > seek_rem) break;

                        if (child.id == ebml.ID_SEEK_ID) {
                            seek_id = try ebml.readUint(r, child.size);
                        } else if (child.id == ebml.ID_SEEK_POSITION) {
                            seek_pos = try ebml.readUint(r, child.size);
                        } else {
                            try ebml.skipBytes(r, child.size);
                        }
                        if (child.size != ebml.UNKNOWN_SIZE) seek_rem -= child.size;
                    }

                    if (seek_id == ebml.ID_CUES and seek_pos != null) {
                        cues_pos = segment_data_pos + seek_pos.?;
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) seek_head_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_INFO) {
            var info_rem = elem.size;
            while (info_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                info_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > info_rem) break;

                if (sub.id == ebml.ID_TIMESTAMP_SCALE) {
                    const val = try ebml.readUint(r, sub.size);
                    timestamp_scale = @floatFromInt(val);
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) info_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_TRACKS) {
            var tracks_rem = elem.size;
            while (tracks_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                tracks_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > tracks_rem) break;

                if (sub.id == ebml.ID_TRACK_ENTRY) {
                    var entry_rem = sub.size;
                    var t_num: ?u64 = null;
                    var t_type: ?u64 = null;
                    var t_codec: ?[]const u8 = null;
                    var t_private: ?[]const u8 = null;
                    var t_w: u32 = 0;
                    var t_h: u32 = 0;
                    var t_rate: u32 = 48000;
                    var t_chan: u16 = 2;

                    while (entry_rem > 0) {
                        const child = (try ebml.readElementHeader(r)) orelse break;
                        entry_rem -= child.header_size;
                        if (child.size != ebml.UNKNOWN_SIZE and child.size > entry_rem) break;

                        if (child.id == ebml.ID_TRACK_NUMBER) {
                            t_num = try ebml.readUint(r, child.size);
                        } else if (child.id == ebml.ID_TRACK_TYPE) {
                            t_type = try ebml.readUint(r, child.size);
                        } else if (child.id == ebml.ID_CODEC_ID) {
                            t_codec = try ebml.readString(arena, r, child.size);
                        } else if (child.id == ebml.ID_CODEC_PRIVATE) {
                            const buf = try arena.alloc(u8, @intCast(child.size));
                            try r.readSliceAll(buf);
                            t_private = buf;
                        } else if (child.id == ebml.ID_VIDEO) {
                            var v_rem = child.size;
                            while (v_rem > 0) {
                                const v_child = (try ebml.readElementHeader(r)) orelse break;
                                v_rem -= v_child.header_size;
                                if (v_child.size != ebml.UNKNOWN_SIZE and v_child.size > v_rem) break;
                                if (v_child.id == ebml.ID_PIXEL_WIDTH) {
                                    t_w = @intCast(try ebml.readUint(r, v_child.size));
                                } else if (v_child.id == ebml.ID_PIXEL_HEIGHT) {
                                    t_h = @intCast(try ebml.readUint(r, v_child.size));
                                } else {
                                    try ebml.skipBytes(r, v_child.size);
                                }
                                if (v_child.size != ebml.UNKNOWN_SIZE) v_rem -= v_child.size;
                            }
                        } else if (child.id == ebml.ID_AUDIO) {
                            var a_rem = child.size;
                            while (a_rem > 0) {
                                const a_child = (try ebml.readElementHeader(r)) orelse break;
                                a_rem -= a_child.header_size;
                                if (a_child.size != ebml.UNKNOWN_SIZE and a_child.size > a_rem) break;
                                if (a_child.id == ebml.ID_SAMPLING_FREQUENCY) {
                                    t_rate = @intFromFloat(try ebml.readFloat(r, a_child.size));
                                } else if (a_child.id == ebml.ID_CHANNELS) {
                                    t_chan = @intCast(try ebml.readUint(r, a_child.size));
                                } else {
                                    try ebml.skipBytes(r, a_child.size);
                                }
                                if (a_child.size != ebml.UNKNOWN_SIZE) a_rem -= a_child.size;
                            }
                        } else {
                            try ebml.skipBytes(r, child.size);
                        }
                        if (child.size != ebml.UNKNOWN_SIZE) entry_rem -= child.size;
                    }

                    if (t_num != null and t_type != null and t_codec != null) {
                        const trk = TrackInfo{
                            .track_num = t_num.?,
                            .track_type = t_type.?,
                            .codec_id = t_codec.?,
                            .codec_private = t_private,
                            .width = t_w,
                            .height = t_h,
                            .sample_rate = t_rate,
                            .channels = t_chan,
                        };
                        if (t_type.? == 1 and video_track_opt == null) {
                            video_track_opt = trk;
                        } else if (t_type.? == 2 and audio_track_opt == null) {
                            audio_track_opt = trk;
                        }
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) tracks_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_CLUSTER) {
            if (first_cluster_pos == null) {
                first_cluster_pos = file_reader.logicalPos() - elem.header_size;
            }
            break;
        } else {
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    if (video_track_opt == null) return error.NoVideoTrack;
    const video = video_track_opt.?;

    // Check Audio format compatibility:
    // If the movie has an audio track that is NOT AAC (e.g. AC-3, DTS, EAC3),
    // web browsers require transcoding to AAC. Until Phase 4 pure-Zig audio decoding is wired in,
    // we yield to the FFmpeg transcoder path so playback succeeds.
    if (audio_track_opt) |aud| {
        if (!std.mem.eql(u8, aud.codec_id, "A_AAC")) {
            std.debug.print("[Native Streamer] Audio track is {s} (requires AAC transcoding) -> delegating to FFmpeg\n", .{aud.codec_id});
            return error.AudioTranscodingRequired;
        }
    }

    // Determine Video Codec
    var video_codec: mp4_muxer.VideoCodecType = .h264;
    if (std.mem.eql(u8, video.codec_id, "V_MPEGH/ISO/HEVC")) {
        video_codec = .hevc;
    } else if (std.mem.eql(u8, video.codec_id, "V_AV1")) {
        video_codec = .av1;
    } else if (std.mem.eql(u8, video.codec_id, "V_VP9")) {
        video_codec = .vp9;
    }

    // 2. Initialize MP4 Muxer & write Init Segment (ftyp + moov)
    var box_builder = mp4_muxer.BoxBuilder.init(allocator);
    defer box_builder.deinit();

    try mp4_muxer.writeFtyp(&box_builder);

    const video_cfg = mp4_muxer.VideoTrackConfig{
        .width = if (video.width > 0) video.width else 1920,
        .height = if (video.height > 0) video.height else 1080,
        .codec = video_codec,
        .codec_private = video.codec_private,
        .timescale = 90000,
    };

    var audio_cfg: ?mp4_muxer.AudioTrackConfig = null;
    if (audio_track_opt) |aud| {
        if (std.mem.eql(u8, aud.codec_id, "A_AAC")) {
            audio_cfg = .{
                .sample_rate = aud.sample_rate,
                .channels = aud.channels,
                .codec_private = aud.codec_private orelse &[_]u8{ 0x11, 0x90 }, // 48kHz stereo fallback
                .timescale = aud.sample_rate,
            };
        }
    }

    try mp4_muxer.writeMoov(&box_builder, video_cfg, audio_cfg);

    // Send Init Segment immediately to HTTP client
    try writer.writer.writeAll(box_builder.buf.items);
    box_builder.buf.clearRetainingCapacity();

    // 3. Fast Seek to Target Keyframe Cluster if start_time > 0
    if (start_time > 0.0) {
        _ = native_metadata.getKeyframePts(io, file_path, start_time) catch start_time;
    }

    // Rewind or jump to first cluster
    if (first_cluster_pos) |pos| {
        try file_reader.seekTo(pos);
    }

    // 4. Stream Clusters & Output Movie Fragments
    var sequence_number: u32 = 1;
    var base_decode_time_video: u64 = 0;
    var base_decode_time_audio: u64 = 0;
    const video_timescale: f64 = 90000.0;

    var video_samples = std.ArrayList(mp4_muxer.SampleInfo).empty;
    defer video_samples.deinit(allocator);

    var video_payload = std.ArrayList(u8).empty;
    defer video_payload.deinit(allocator);

    var audio_samples = std.ArrayList(mp4_muxer.SampleInfo).empty;
    defer audio_samples.deinit(allocator);

    var audio_payload = std.ArrayList(u8).empty;
    defer audio_payload.deinit(allocator);

    var current_cluster_ts_ns: u64 = 0;
    var first_pts_ns: ?u64 = null;
    var last_pts_ns: u64 = 0;

    var block_buf = std.ArrayList(u8).empty;
    defer block_buf.deinit(allocator);

    while (true) {
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_CLUSTER) {
            // Flush existing fragments on cluster boundary
            if (video_samples.items.len > 0) {
                try mp4_muxer.writeFragment(&box_builder, sequence_number, 1, base_decode_time_video, video_samples.items, video_payload.items);
                try writer.writer.writeAll(box_builder.buf.items);
                box_builder.buf.clearRetainingCapacity();

                var total_dur: u64 = 0;
                for (video_samples.items) |s| total_dur += s.duration;
                base_decode_time_video += total_dur;
                sequence_number += 1;

                video_samples.clearRetainingCapacity();
                video_payload.clearRetainingCapacity();
            }

            if (audio_samples.items.len > 0) {
                try mp4_muxer.writeFragment(&box_builder, sequence_number, 2, base_decode_time_audio, audio_samples.items, audio_payload.items);
                try writer.writer.writeAll(box_builder.buf.items);
                box_builder.buf.clearRetainingCapacity();

                var total_dur: u64 = 0;
                for (audio_samples.items) |s| total_dur += s.duration;
                base_decode_time_audio += total_dur;
                sequence_number += 1;

                audio_samples.clearRetainingCapacity();
                audio_payload.clearRetainingCapacity();
            }

            var cluster_rem = elem.size;
            while (cluster_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                cluster_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cluster_rem) break;

                if (sub.id == ebml.ID_CLUSTER_TIMESTAMP) {
                    const ts_val = try ebml.readUint(r, sub.size);
                    current_cluster_ts_ns = @intFromFloat(@as(f64, @floatFromInt(ts_val)) * timestamp_scale);
                } else if (sub.id == ebml.ID_SIMPLE_BLOCK or sub.id == ebml.ID_BLOCK) {
                    const is_simple = (sub.id == ebml.ID_SIMPLE_BLOCK);
                    block_buf.clearRetainingCapacity();
                    try block_buf.ensureTotalCapacityPrecise(allocator, @intCast(sub.size));
                    block_buf.items.len = @intCast(sub.size);
                    try r.readSliceAll(block_buf.items);

                    const track_vint = ebml.decodeVint(block_buf.items) catch continue;
                    const track_num = track_vint.value;

                    if (track_num == video.track_num) {
                        const rel_timecode = std.mem.readInt(i16, block_buf.items[track_vint.len..][0..2], .big);
                        const flags = block_buf.items[track_vint.len + 2];
                        const is_keyframe = is_simple and ((flags & 0x80) != 0);

                        const block_pts_ns = if (rel_timecode >= 0)
                            current_cluster_ts_ns + @as(u64, @intCast(rel_timecode)) * @as(u64, @intFromFloat(timestamp_scale))
                        else
                            current_cluster_ts_ns - @as(u64, @intCast(-rel_timecode)) * @as(u64, @intFromFloat(timestamp_scale));

                        if (first_pts_ns == null) {
                            first_pts_ns = block_pts_ns;
                            last_pts_ns = block_pts_ns;
                        }

                        const dur_ns = if (block_pts_ns > last_pts_ns) (block_pts_ns - last_pts_ns) else 33_333_333;
                        last_pts_ns = block_pts_ns;
                        const dur_ticks: u32 = @intFromFloat(@as(f64, @floatFromInt(dur_ns)) * video_timescale / 1_000_000_000.0);

                        const header_len = track_vint.len + 3;
                        if (block_buf.items.len > header_len) {
                            const raw_data = block_buf.items[header_len..];
                            const sample_start = video_payload.items.len;

                            try appendNalUnits(allocator, &video_payload, raw_data);

                            const sample_size: u32 = @intCast(video_payload.items.len - sample_start);
                            try video_samples.append(allocator, .{
                                .duration = if (dur_ticks > 0) dur_ticks else 3000,
                                .size = sample_size,
                                .is_keyframe = is_keyframe,
                                .composition_time_offset = 0,
                            });
                        }
                    } else if (audio_track_opt != null and track_num == audio_track_opt.?.track_num) {
                        const header_len = track_vint.len + 3;
                        if (block_buf.items.len > header_len) {
                            const raw_data = block_buf.items[header_len..];
                            try audio_payload.appendSlice(allocator, raw_data);
                            try audio_samples.append(allocator, .{
                                .duration = 1024, // 1024 samples per AAC frame
                                .size = @intCast(raw_data.len),
                                .is_keyframe = true,
                                .composition_time_offset = 0,
                            });
                        }
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) cluster_rem -= sub.size;
            }
        } else {
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    // Flush any remaining samples
    if (video_samples.items.len > 0) {
        try mp4_muxer.writeFragment(&box_builder, sequence_number, 1, base_decode_time_video, video_samples.items, video_payload.items);
        try writer.writer.writeAll(box_builder.buf.items);
        box_builder.buf.clearRetainingCapacity();
        sequence_number += 1;
    }
    if (audio_samples.items.len > 0) {
        try mp4_muxer.writeFragment(&box_builder, sequence_number, 2, base_decode_time_audio, audio_samples.items, audio_payload.items);
        try writer.writer.writeAll(box_builder.buf.items);
    }
}

test "slicer streaming Tuner.mkv to memory" {
    const path = "/Users/borisk/Movies/Sratim/Movies/Tuner.mkv";
    var io_threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    const file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
    file.close(io);

    // Mock BodyWriter that writes into an ArrayList(u8)
    const MockWriter = struct {
        buf: std.ArrayList(u8),
        pub fn write(self: *@This(), bytes: []const u8) !usize {
            try self.buf.appendSlice(std.testing.allocator, bytes);
            return bytes.len;
        }
    };
    var mock = MockWriter{ .buf = std.ArrayList(u8).empty };
    defer mock.buf.deinit(std.testing.allocator);

    // Let's inspect the generated ftyp and moov directly
    var builder = mp4_muxer.BoxBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try mp4_muxer.writeFtyp(&builder);
    const video_cfg = mp4_muxer.VideoTrackConfig{
        .width = 1920,
        .height = 1080,
        .codec = .hevc,
        .codec_private = &[_]u8{ 0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x5d, 0xf0, 0x00, 0xfc, 0xfd, 0xfa, 0xfa, 0x00, 0x00, 0x0f, 0x03, 0x20, 0x00, 0x01, 0x00, 0x18, 0x40, 0x01, 0x0c, 0x01 },
        .timescale = 90000,
    };
    const audio_cfg = mp4_muxer.AudioTrackConfig{
        .sample_rate = 48000,
        .channels = 2,
        .codec_private = &[_]u8{ 0x11, 0x80 },
        .timescale = 48000,
    };
    try mp4_muxer.writeMoov(&builder, video_cfg, audio_cfg);

    std.debug.print("Init segment size = {d} bytes\n", .{builder.buf.items.len});
    // Check boxes in init segment
    var offset: usize = 0;
    while (offset + 8 <= builder.buf.items.len) {
        const box_size = std.mem.readInt(u32, builder.buf.items[offset..][0..4], .big);
        const fourcc = builder.buf.items[offset + 4 .. offset + 8];
        std.debug.print("Top-level box: {s}, size: {d}\n", .{ fourcc, box_size });
        if (box_size == 0) break;
        offset += box_size;
    }
}

test "appendNalUnits Annex B conversion" {
    const testing = std.testing;
    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(testing.allocator);

    // 4-byte Annex B
    const raw_4 = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x00, 0x01, 0x68, 0xCE };
    try appendNalUnits(testing.allocator, &payload, &raw_4);
    // Expect: [0, 0, 0, 2, 0x67, 0x42, 0, 0, 0, 2, 0x68, 0xCE]
    try testing.expectEqual(@as(usize, 12), payload.items.len);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload.items[0..4], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload.items[6..10], .big));

    payload.clearRetainingCapacity();

    // 3-byte Annex B
    const raw_3 = [_]u8{ 0x00, 0x00, 0x01, 0x65, 0x88, 0x00, 0x00, 0x01, 0x41, 0x9A };
    try appendNalUnits(testing.allocator, &payload, &raw_3);
    try testing.expectEqual(@as(usize, 12), payload.items.len);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload.items[0..4], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, payload.items[6..10], .big));
}
