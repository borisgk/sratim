const std = @import("std");
const ebml = @import("ebml.zig");

pub const CueSeekResult = struct {
    pts_sec: f64,
    cluster_offset: u64,
};

/// Parses a Matroska Cues element to find the nearest previous video keyframe timestamp and cluster byte offset.
pub fn parseCuesWithOffset(
    r: *std.Io.Reader,
    cues_elem: ebml.ElementHeader,
    timestamp_scale: f64,
    segment_data_pos: u64,
    start_time: f64,
    video_track_num: ?u64,
) !CueSeekResult {
    var cues_rem = cues_elem.size;
    var best_ts_sec: f64 = 0.0;
    var best_cluster_offset: u64 = 0;

    while (cues_rem > 0) {
        const sub = (try ebml.readElementHeader(r)) orelse break;
        cues_rem -= sub.header_size;
        if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cues_rem) break;

        if (sub.id == ebml.ID_CUE_POINT) {
            var cp_rem = sub.size;
            var cue_time_raw: ?u64 = null;
            var cue_cluster_pos_raw: ?u64 = null;
            var cue_track_match: bool = (video_track_num == null);

            while (cp_rem > 0) {
                const cp_child = (try ebml.readElementHeader(r)) orelse break;
                cp_rem -= cp_child.header_size;
                if (cp_child.size != ebml.UNKNOWN_SIZE and cp_child.size > cp_rem) break;

                if (cp_child.id == ebml.ID_CUE_TIME) {
                    cue_time_raw = try ebml.readUint(r, cp_child.size);
                } else if (cp_child.id == ebml.ID_CUE_TRACK_POSITIONS) {
                    var ctp_rem = cp_child.size;
                    while (ctp_rem > 0) {
                        const ctp_child = (try ebml.readElementHeader(r)) orelse break;
                        ctp_rem -= ctp_child.header_size;
                        if (ctp_child.size != ebml.UNKNOWN_SIZE and ctp_child.size > ctp_rem) break;

                        if (ctp_child.id == ebml.ID_CUE_TRACK) {
                            const track_num = try ebml.readUint(r, ctp_child.size);
                            if (video_track_num != null and track_num == video_track_num.?) {
                                cue_track_match = true;
                            }
                        } else if (ctp_child.id == ebml.ID_CUE_CLUSTER_POSITION) {
                            cue_cluster_pos_raw = try ebml.readUint(r, ctp_child.size);
                        } else {
                            try ebml.skipBytes(r, ctp_child.size);
                        }
                        if (ctp_child.size != ebml.UNKNOWN_SIZE) ctp_rem -= ctp_child.size;
                    }
                } else {
                    try ebml.skipBytes(r, cp_child.size);
                }
                if (cp_child.size != ebml.UNKNOWN_SIZE) cp_rem -= cp_child.size;
            }

            if (cue_time_raw) |raw| {
                if (cue_track_match) {
                    const ts_sec = (@as(f64, @floatFromInt(raw)) * timestamp_scale) / 1_000_000_000.0;
                    const cluster_abs_offset = if (cue_cluster_pos_raw) |pos| segment_data_pos + pos else 0;
                    if (ts_sec <= start_time) {
                        best_ts_sec = ts_sec;
                        best_cluster_offset = cluster_abs_offset;
                    } else {
                        return CueSeekResult{ .pts_sec = best_ts_sec, .cluster_offset = best_cluster_offset };
                    }
                }
            }
        } else {
            try ebml.skipBytes(r, sub.size);
        }
        if (sub.size != ebml.UNKNOWN_SIZE) cues_rem -= sub.size;
    }

    return CueSeekResult{ .pts_sec = best_ts_sec, .cluster_offset = best_cluster_offset };
}

/// Parses a Matroska Cues element to find the nearest previous video keyframe timestamp in seconds.
pub fn parseCues(r: *std.Io.Reader, cues_elem: ebml.ElementHeader, timestamp_scale: f64, start_time: f64, video_track_num: ?u64) !f64 {
    const res = try parseCuesWithOffset(r, cues_elem, timestamp_scale, 0, start_time, video_track_num);
    return res.pts_sec;
}

/// Pure Zig keyframe PTS finder for Matroska files.
/// Inspects Cues (or Cluster headers) to find the nearest previous keyframe timestamp and cluster byte offset.
pub fn findCueSeekPosition(io: std.Io, file_path: []const u8, start_time: f64) !CueSeekResult {
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
    var video_track_num: ?u64 = null;

    var first_cluster_pos: ?u64 = null;

    while (true) {
        const elem_pos = file_reader.logicalPos();
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_SEEK_HEAD) {
            var seek_head_rem = elem.size;
            while (seek_head_rem > 0) {
                const sub = (try ebml.readElementHeader(r)) orelse break;
                seek_head_rem -= sub.header_size;
                if (sub.size != ebml.UNKNOWN_SIZE and sub.size > seek_head_rem) break;

                if (sub.id == ebml.ID_SEEK) {
                    var seek_rem = sub.size;
                    var seek_id: ?u32 = null;
                    var seek_pos: ?u64 = null;

                    while (seek_rem > 0) {
                        const child = (try ebml.readElementHeader(r)) orelse break;
                        seek_rem -= child.header_size;
                        if (child.size != ebml.UNKNOWN_SIZE and child.size > seek_rem) break;

                        if (child.id == ebml.ID_SEEK_ID) {
                            seek_id = @intCast(try ebml.readUint(r, child.size));
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

                    while (entry_rem > 0) {
                        const trk_child = (try ebml.readElementHeader(r)) orelse break;
                        entry_rem -= trk_child.header_size;
                        if (trk_child.size != ebml.UNKNOWN_SIZE and trk_child.size > entry_rem) break;

                        if (trk_child.id == ebml.ID_TRACK_NUMBER) {
                            t_num = try ebml.readUint(r, trk_child.size);
                        } else if (trk_child.id == ebml.ID_TRACK_TYPE) {
                            t_type = try ebml.readUint(r, trk_child.size);
                        } else {
                            try ebml.skipBytes(r, trk_child.size);
                        }
                        if (trk_child.size != ebml.UNKNOWN_SIZE) entry_rem -= trk_child.size;
                    }

                    if (t_type) |tt| {
                        if (tt == 1 and video_track_num == null) { // 1 = Video
                            video_track_num = t_num;
                        }
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) tracks_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_CUES) {
            return parseCuesWithOffset(r, elem, timestamp_scale, segment_data_pos, start_time, video_track_num);
        } else if (elem.id == ebml.ID_CLUSTER) {
            if (first_cluster_pos == null) first_cluster_pos = elem_pos;
            if (cues_pos) |pos| {
                file_reader.seekTo(pos) catch {};
                const cue_elem = (try ebml.readElementHeader(r)) orelse return CueSeekResult{ .pts_sec = 0.0, .cluster_offset = first_cluster_pos.? };
                if (cue_elem.id == ebml.ID_CUES) {
                    return parseCuesWithOffset(r, cue_elem, timestamp_scale, segment_data_pos, start_time, video_track_num);
                }
            }
            return CueSeekResult{ .pts_sec = 0.0, .cluster_offset = first_cluster_pos.? };
        } else {
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    if (cues_pos) |pos| {
        file_reader.seekTo(pos) catch {};
        const cue_elem = (try ebml.readElementHeader(r)) orelse return CueSeekResult{ .pts_sec = 0.0, .cluster_offset = first_cluster_pos orelse 0 };
        if (cue_elem.id == ebml.ID_CUES) {
            return parseCuesWithOffset(r, cue_elem, timestamp_scale, segment_data_pos, start_time, video_track_num);
        }
    }

    return CueSeekResult{ .pts_sec = 0.0, .cluster_offset = first_cluster_pos orelse 0 };
}

/// Pure Zig keyframe PTS finder for Matroska files.
pub fn getKeyframePts(io: std.Io, file_path: []const u8, start_time: f64) !f64 {
    const res = findCueSeekPosition(io, file_path, start_time) catch return start_time;
    return res.pts_sec;
}

test "parseCues binary parsing" {
    const raw_cues = [_]u8{
        0xBB, 0x84, 0xB3, 0x82, 0x13, 0x88, // CuePoint 1: CueTime = 0x1388 (5000 ms = 5.0s)
        0xBB, 0x84, 0xB3, 0x82, 0x3A, 0x98, // CuePoint 2: CueTime = 0x3A98 (15000 ms = 15.0s)
    };
    var r: std.Io.Reader = .fixed(&raw_cues);
    const cues_elem = ebml.ElementHeader{
        .id = ebml.ID_CUES,
        .size = raw_cues.len,
        .header_size = 0,
    };

    const pts = try parseCues(&r, cues_elem, 1_000_000.0, 10.0, null);
    try std.testing.expectEqual(@as(f64, 5.0), pts);
}

test "parseCues filters specifically by video track number" {
    // CuePoint 1: CueTime = 1000ms (1.0s), CueTrack = 3 (Subtitle)
    // CuePoint 2: CueTime = 4000ms (4.0s), CueTrack = 1 (Video)
    // CuePoint 3: CueTime = 5000ms (5.0s), CueTrack = 3 (Subtitle)
    const raw_cues = [_]u8{
        // CuePoint 1
        0xBB, 0x89,
        0xB3, 0x82, 0x03, 0xE8, // CueTime = 1000
        0xB7, 0x83, 0xF7, 0x81, 0x03, // CueTrackPositions: CueTrack = 3
        // CuePoint 2
        0xBB, 0x89,
        0xB3, 0x82, 0x0F, 0xA0, // CueTime = 4000
        0xB7, 0x83, 0xF7, 0x81, 0x01, // CueTrackPositions: CueTrack = 1
        // CuePoint 3
        0xBB, 0x89,
        0xB3, 0x82, 0x13, 0x88, // CueTime = 5000
        0xB7, 0x83, 0xF7, 0x81, 0x03, // CueTrackPositions: CueTrack = 3
    };
    var r: std.Io.Reader = .fixed(&raw_cues);
    const cues_elem = ebml.ElementHeader{
        .id = ebml.ID_CUES,
        .size = raw_cues.len,
        .header_size = 0,
    };

    // When seeking to 5.0s, video track 1 should match CuePoint 2 (4.0s) and ignore CuePoint 3 (5.0s, subtitle track)
    const pts = try parseCues(&r, cues_elem, 1_000_000.0, 5.0, 1);
    try std.testing.expectEqual(@as(f64, 4.0), pts);
}
