const std = @import("std");
const ebml = @import("ebml.zig");

/// Parses a Matroska Cues element to find the nearest previous keyframe timestamp in seconds.
pub fn parseCues(r: *std.Io.Reader, cues_elem: ebml.ElementHeader, timestamp_scale: f64, start_time: f64) !f64 {
    var cues_rem = cues_elem.size;
    var best_ts_sec: f64 = 0.0;

    while (cues_rem > 0) {
        const sub = (try ebml.readElementHeader(r)) orelse break;
        cues_rem -= sub.header_size;
        if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cues_rem) break;

        if (sub.id == ebml.ID_CUE_POINT) {
            var cp_rem = sub.size;
            var cue_time_raw: ?u64 = null;

            while (cp_rem > 0) {
                const cp_child = (try ebml.readElementHeader(r)) orelse break;
                cp_rem -= cp_child.header_size;
                if (cp_child.size != ebml.UNKNOWN_SIZE and cp_child.size > cp_rem) break;

                if (cp_child.id == ebml.ID_CUE_TIME) {
                    cue_time_raw = try ebml.readUint(r, cp_child.size);
                } else {
                    try ebml.skipBytes(r, cp_child.size);
                }
                if (cp_child.size != ebml.UNKNOWN_SIZE) cp_rem -= cp_child.size;
            }

            if (cue_time_raw) |raw| {
                const ts_sec = (@as(f64, @floatFromInt(raw)) * timestamp_scale) / 1_000_000_000.0;
                if (ts_sec <= start_time) {
                    best_ts_sec = ts_sec;
                } else {
                    return best_ts_sec;
                }
            }
        } else {
            try ebml.skipBytes(r, sub.size);
        }
        if (sub.size != ebml.UNKNOWN_SIZE) cues_rem -= sub.size;
    }

    return best_ts_sec;
}

/// Pure Zig keyframe PTS finder for Matroska files.
/// Inspects Cues (or Cluster headers) to find the nearest previous keyframe timestamp in seconds.
pub fn getKeyframePts(io: std.Io, file_path: []const u8, start_time: f64) !f64 {
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

    var best_cluster_time: ?f64 = null;

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
        } else if (elem.id == ebml.ID_CUES) {
            return parseCues(r, elem, timestamp_scale, start_time);
        } else if (elem.id == ebml.ID_CLUSTER) {
            // If we encounter a cluster and haven't jumped to Cues yet
            if (cues_pos) |pos| {
                file_reader.seekTo(pos) catch {};
                const cue_elem = (try ebml.readElementHeader(r)) orelse return start_time;
                if (cue_elem.id == ebml.ID_CUES) {
                    return parseCues(r, cue_elem, timestamp_scale, start_time);
                }
            }

            // Fallback: scan cluster timestamps
            var cluster_elem: ?ebml.ElementHeader = elem;
            while (cluster_elem) |ce| {
                var cl_rem = ce.size;
                while (cl_rem > 0) {
                    const sub = (try ebml.readElementHeader(r)) orelse break;
                    cl_rem -= sub.header_size;
                    if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cl_rem) break;

                    if (sub.id == ebml.ID_CLUSTER_TIMESTAMP) {
                        const cl_ts = try ebml.readUint(r, sub.size);
                        const ts_sec = (@as(f64, @floatFromInt(cl_ts)) * timestamp_scale) / 1_000_000_000.0;
                        if (ts_sec <= start_time) {
                            best_cluster_time = ts_sec;
                        } else {
                            return best_cluster_time orelse start_time;
                        }
                        cl_rem -= sub.size;
                        break;
                    } else {
                        try ebml.skipBytes(r, sub.size);
                        cl_rem -= sub.size;
                    }
                }

                if (ce.size != ebml.UNKNOWN_SIZE) {
                    try ebml.skipBytes(r, cl_rem);
                }

                // Read next cluster
                cluster_elem = null;
                while (true) {
                    const next = (try ebml.readElementHeader(r)) orelse break;
                    if (next.id == ebml.ID_CLUSTER) {
                        cluster_elem = next;
                        break;
                    } else if (next.size != ebml.UNKNOWN_SIZE) {
                        try ebml.skipBytes(r, next.size);
                    }
                }
            }
            return best_cluster_time orelse start_time;
        } else {
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    if (cues_pos) |pos| {
        file_reader.seekTo(pos) catch {};
        const cue_elem = (try ebml.readElementHeader(r)) orelse return start_time;
        if (cue_elem.id == ebml.ID_CUES) {
            return parseCues(r, cue_elem, timestamp_scale, start_time);
        }
    }

    return start_time;
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

    const pts = try parseCues(&r, cues_elem, 1_000_000.0, 10.0);
    try std.testing.expectEqual(@as(f64, 5.0), pts);
}
