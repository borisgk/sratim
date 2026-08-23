const std = @import("std");
const ebml = @import("ebml.zig");

pub fn formatVttTime(writer: anytype, total_seconds: f64) !void {
    const sec_val = if (total_seconds < 0) 0.0 else total_seconds;
    const total_ms: u64 = @intFromFloat(sec_val * 1000.0);
    const hours = total_ms / (3600 * 1000);
    const mins = (total_ms % (3600 * 1000)) / (60 * 1000);
    const secs = (total_ms % (60 * 1000)) / 1000;
    const ms = total_ms % 1000;

    try writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, mins, secs, ms });
}

pub fn cleanAssText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ass_raw: []const u8) !void {
    var text = std.mem.trim(u8, ass_raw, " \t\r\n\x00");
    if (text.len == 0) return;

    var is_dialogue_prefix = false;

    if (text.len >= 9 and std.ascii.eqlIgnoreCase(text[0..9], "dialogue:")) {
        text = std.mem.trimStart(u8, text[9..], " \t");
        is_dialogue_prefix = true;
    } else if (text.len >= 8 and std.ascii.eqlIgnoreCase(text[0..8], "comment:")) {
        text = std.mem.trimStart(u8, text[8..], " \t");
        is_dialogue_prefix = true;
    }

    if (is_dialogue_prefix) {
        var commas: usize = 0;
        for (text, 0..) |ch, idx| {
            if (ch == ',') {
                commas += 1;
                if (commas == 9) {
                    text = text[idx + 1 ..];
                    break;
                }
            }
        }
    } else {
        var commas: usize = 0;
        var eighth_comma_idx: ?usize = null;

        for (text, 0..) |ch, idx| {
            if (ch == ',') {
                commas += 1;
                if (commas == 8) {
                    eighth_comma_idx = idx;
                    break;
                }
            }
        }

        if (eighth_comma_idx) |idx| {
            const prefix = text[0..idx];
            if (std.mem.indexOf(u8, prefix, "Default") != null or
                std.mem.indexOf(u8, prefix, "0,0,0") != null or
                std.mem.indexOf(u8, prefix, "0:00:") != null)
            {
                text = text[idx + 1 ..];
            }
        }
    }

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            while (i < text.len and text[i] != '}') : (i += 1) {}
            if (i < text.len) i += 1;
        } else if (i + 1 < text.len and text[i] == '\\' and (text[i + 1] == 'N' or text[i + 1] == 'n')) {
            try out.append(allocator, '\n');
            i += 2;
        } else if (i + 1 < text.len and text[i] == '\\' and (text[i + 1] == 'h' or text[i + 1] == 'H')) {
            try out.append(allocator, ' ');
            i += 2;
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }
}

/// Peeks a small sample of text from a specific subtitle stream for language detection.
pub fn peekSubtitleSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    target_stream_idx: usize,
) !?[]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    const ebml_hdr = (try ebml.readElementHeader(r)) orelse return null;
    if (ebml_hdr.id != ebml.ID_EBML) return null;
    try ebml.skipBytes(r, ebml_hdr.size);

    const seg_hdr = (try ebml.readElementHeader(r)) orelse return null;
    if (seg_hdr.id != ebml.ID_SEGMENT) return null;

    var current_stream_idx: usize = 0;
    var target_track_num: ?u64 = null;
    var first_cluster_elem: ?ebml.ElementHeader = null;

    while (true) {
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_TRACKS) {
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
                        if (current_stream_idx == target_stream_idx and tt == 17) {
                            if (t_num) |num| {
                                target_track_num = num;
                            }
                        }
                        current_stream_idx += 1;
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) tracks_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_CLUSTER) {
            if (first_cluster_elem == null) {
                first_cluster_elem = elem;
            }
            break;
        } else {
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    if (target_track_num == null or first_cluster_elem == null) {
        return null;
    }

    var sample_buf = std.ArrayList(u8).empty;
    defer sample_buf.deinit(allocator);

    var cluster_elem: ?ebml.ElementHeader = first_cluster_elem;
    var cues_collected: usize = 0;

    var text_buf = std.ArrayList(u8).empty;
    defer text_buf.deinit(allocator);

    while (cluster_elem) |ce| {
        var cluster_rem: u64 = ce.size;

        while (cluster_rem > 0) {
            const sub = (try ebml.readElementHeader(r)) orelse break;
            cluster_rem -= sub.header_size;
            if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cluster_rem) break;

            if (sub.id == ebml.ID_SIMPLE_BLOCK or sub.id == ebml.ID_BLOCK) {
                if (sub.size < 4) {
                    try ebml.skipBytes(r, sub.size);
                    cluster_rem -= sub.size;
                    continue;
                }

                const peek_len: usize = @intCast(@min(sub.size, 16));
                var header_buf: [16]u8 = undefined;
                try r.readSliceAll(header_buf[0..peek_len]);

                const track_res = ebml.decodeVint(header_buf[0..peek_len]) catch {
                    try ebml.skipBytes(r, sub.size - peek_len);
                    cluster_rem -= sub.size;
                    continue;
                };

                if (track_res.value != target_track_num.?) {
                    try ebml.skipBytes(r, sub.size - peek_len);
                    cluster_rem -= sub.size;
                    continue;
                }

                const hdr_len = track_res.len + 3;
                if (sub.size < hdr_len) {
                    try ebml.skipBytes(r, sub.size - peek_len);
                    cluster_rem -= sub.size;
                    continue;
                }

                const payload_len: usize = @intCast(sub.size - hdr_len);
                const payload = try allocator.alloc(u8, payload_len);
                defer allocator.free(payload);

                const already_in_hdr = if (peek_len > hdr_len) peek_len - hdr_len else 0;
                if (already_in_hdr > 0) {
                    @memcpy(payload[0..already_in_hdr], header_buf[hdr_len..peek_len]);
                }
                const rem_to_read = payload_len - already_in_hdr;
                if (rem_to_read > 0) {
                    try r.readSliceAll(payload[already_in_hdr..]);
                }
                cluster_rem -= sub.size;

                text_buf.clearRetainingCapacity();
                try cleanAssText(&text_buf, allocator, payload);
                const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
                if (trimmed.len > 0) {
                    if (sample_buf.items.len > 0) try sample_buf.append(allocator, ' ');
                    try sample_buf.appendSlice(allocator, trimmed);
                    cues_collected += 1;
                    if (cues_collected >= 3 or sample_buf.items.len >= 300) {
                        return try sample_buf.toOwnedSlice(allocator);
                    }
                }
            } else if (sub.id == ebml.ID_BLOCK_GROUP) {
                var bg_rem: u64 = sub.size;
                var block_payload: ?[]u8 = null;
                defer if (block_payload) |bp| allocator.free(bp);

                while (bg_rem > 0) {
                    const bg_child = (try ebml.readElementHeader(r)) orelse break;
                    bg_rem -= bg_child.header_size;
                    if (bg_child.size != ebml.UNKNOWN_SIZE and bg_child.size > bg_rem) break;

                    if (bg_child.id == ebml.ID_BLOCK) {
                        if (bg_child.size < 4) {
                            try ebml.skipBytes(r, bg_child.size);
                            bg_rem -= bg_child.size;
                            continue;
                        }

                        const peek_len: usize = @intCast(@min(bg_child.size, 16));
                        var header_buf: [16]u8 = undefined;
                        try r.readSliceAll(header_buf[0..peek_len]);

                        const track_res = ebml.decodeVint(header_buf[0..peek_len]) catch {
                            try ebml.skipBytes(r, bg_child.size - peek_len);
                            bg_rem -= bg_child.size;
                            continue;
                        };
                        if (track_res.value == target_track_num.?) {
                            const hdr_len = track_res.len + 3;
                            if (bg_child.size >= hdr_len) {
                                const payload_len: usize = @intCast(bg_child.size - hdr_len);
                                const p_buf = try allocator.alloc(u8, payload_len);
                                errdefer allocator.free(p_buf);

                                const already_in_hdr = if (peek_len > hdr_len) peek_len - hdr_len else 0;
                                if (already_in_hdr > 0) {
                                    @memcpy(p_buf[0..already_in_hdr], header_buf[hdr_len..peek_len]);
                                }
                                const rem_to_read = payload_len - already_in_hdr;
                                if (rem_to_read > 0) {
                                    try r.readSliceAll(p_buf[already_in_hdr..]);
                                }
                                block_payload = p_buf;
                            } else {
                                try ebml.skipBytes(r, bg_child.size - peek_len);
                            }
                        } else {
                            try ebml.skipBytes(r, bg_child.size - peek_len);
                        }
                        bg_rem -= bg_child.size;
                    } else {
                        try ebml.skipBytes(r, bg_child.size);
                        bg_rem -= bg_child.size;
                    }
                }

                if (block_payload) |bp| {
                    text_buf.clearRetainingCapacity();
                    try cleanAssText(&text_buf, allocator, bp);
                    const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
                    if (trimmed.len > 0) {
                        if (sample_buf.items.len > 0) try sample_buf.append(allocator, ' ');
                        try sample_buf.appendSlice(allocator, trimmed);
                        cues_collected += 1;
                        if (cues_collected >= 3 or sample_buf.items.len >= 300) {
                            return try sample_buf.toOwnedSlice(allocator);
                        }
                    }
                }
                cluster_rem -= sub.size;
            } else {
                if (sub.size != ebml.UNKNOWN_SIZE) {
                    try ebml.skipBytes(r, sub.size);
                    cluster_rem -= sub.size;
                }
            }
        }

        cluster_elem = null;
        while (true) {
            const next_elem = (try ebml.readElementHeader(r)) orelse break;
            if (next_elem.id == ebml.ID_CLUSTER) {
                cluster_elem = next_elem;
                break;
            } else if (next_elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, next_elem.size);
            }
        }
    }

    if (sample_buf.items.len > 0) {
        return try sample_buf.toOwnedSlice(allocator);
    }
    return null;
}

/// Pure Zig extraction of embedded subtitles from an MKV file directly to a WebVTT writer.
pub fn extractMkvSubtitlesVtt(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    file_path: [:0]const u8,
    target_stream_idx: usize,
    start_offset: f64,
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    // Read EBML Header
    const ebml_hdr = (try ebml.readElementHeader(r)) orelse return error.InvalidEbml;
    if (ebml_hdr.id != ebml.ID_EBML) return error.NotMatroska;
    try ebml.skipBytes(r, ebml_hdr.size);

    // Read Segment Header
    const seg_hdr = (try ebml.readElementHeader(r)) orelse return error.InvalidEbml;
    if (seg_hdr.id != ebml.ID_SEGMENT) return error.NotMatroska;

    var timestamp_scale: f64 = 1_000_000.0; // Default 1ms = 1,000,000 ns
    var current_stream_idx: usize = 0;
    var target_track_num: ?u64 = null;
    var first_cluster_elem: ?ebml.ElementHeader = null;

    // Scan segment level-1 elements
    while (true) {
        const elem = (try ebml.readElementHeader(r)) orelse break;

        if (elem.id == ebml.ID_INFO) {
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
                        if (current_stream_idx == target_stream_idx and tt == 17) { // 17 = Subtitle
                            if (t_num) |num| {
                                target_track_num = num;
                            }
                        }
                        current_stream_idx += 1;
                    }
                } else {
                    try ebml.skipBytes(r, sub.size);
                }
                if (sub.size != ebml.UNKNOWN_SIZE) tracks_rem -= sub.size;
            }
        } else if (elem.id == ebml.ID_CLUSTER) {
            // First cluster found - save it and break to start cluster scanning
            if (first_cluster_elem == null) {
                first_cluster_elem = elem;
            }
            break;
        } else {
            // Skip other level-1 elements
            if (elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, elem.size);
            }
        }
    }

    if (target_track_num == null or first_cluster_elem == null) {
        return error.NoSubtitleStreamsFound;
    }

    // Output standard WEBVTT header once before extracting cues
    try writer.writeAll("WEBVTT\n\n");
    try parseClusters(allocator, r, first_cluster_elem.?, timestamp_scale, target_track_num.?, start_offset, writer);
}

fn parseClusters(
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    first_cluster_elem: ebml.ElementHeader,
    timestamp_scale: f64,
    target_track_num: u64,
    start_offset: f64,
    writer: anytype,
) !void {
    var cluster_elem: ?ebml.ElementHeader = first_cluster_elem;
    const time_multiplier = timestamp_scale / 1_000_000_000.0;

    var text_buf = std.ArrayList(u8).empty;
    defer text_buf.deinit(allocator);

    while (cluster_elem) |ce| {
        var cluster_timestamp_raw: u64 = 0;
        var cluster_rem: u64 = ce.size;

        while (cluster_rem > 0) {
            const sub = (try ebml.readElementHeader(r)) orelse break;
            cluster_rem -= sub.header_size;
            if (sub.size != ebml.UNKNOWN_SIZE and sub.size > cluster_rem) break;

            if (sub.id == ebml.ID_CLUSTER_TIMESTAMP) {
                cluster_timestamp_raw = try ebml.readUint(r, sub.size);
                cluster_rem -= sub.size;
            } else if (sub.id == ebml.ID_SIMPLE_BLOCK or sub.id == ebml.ID_BLOCK) {
                if (sub.size < 4) {
                    try ebml.skipBytes(r, sub.size);
                    cluster_rem -= sub.size;
                    continue;
                }

                const peek_len: usize = @intCast(@min(sub.size, 16));
                var header_buf: [16]u8 = undefined;
                try r.readSliceAll(header_buf[0..peek_len]);

                const track_res = ebml.decodeVint(header_buf[0..peek_len]) catch {
                    try ebml.skipBytes(r, sub.size - peek_len);
                    cluster_rem -= sub.size;
                    continue;
                };

                if (track_res.value != target_track_num) {
                    try ebml.skipBytes(r, sub.size - peek_len);
                    cluster_rem -= sub.size;
                    continue;
                }

                // Target subtitle track
                const hdr_len = track_res.len + 3; // VINT + 2 bytes timecode + 1 byte flags
                if (sub.size < hdr_len) {
                    try ebml.skipBytes(r, sub.size - peek_len);
                    cluster_rem -= sub.size;
                    continue;
                }

                const rel_timecode = std.mem.readInt(i16, header_buf[track_res.len..][0..2], .big);
                const payload_len: usize = @intCast(sub.size - hdr_len);

                const payload: []u8 = try allocator.alloc(u8, payload_len);
                defer allocator.free(payload);

                const already_in_hdr = if (peek_len > hdr_len) peek_len - hdr_len else 0;
                if (already_in_hdr > 0) {
                    @memcpy(payload[0..already_in_hdr], header_buf[hdr_len..peek_len]);
                }
                const rem_to_read = payload_len - already_in_hdr;
                if (rem_to_read > 0) {
                    try r.readSliceAll(payload[already_in_hdr..]);
                }
                cluster_rem -= sub.size;

                const cue_start_sec = (@as(f64, @floatFromInt(cluster_timestamp_raw)) + @as(f64, @floatFromInt(rel_timecode))) * time_multiplier;
                const cue_end_sec = cue_start_sec + 3.0;

                if (cue_end_sec >= start_offset) {
                    text_buf.clearRetainingCapacity();
                    try cleanAssText(&text_buf, allocator, payload);
                    const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
                    if (trimmed.len > 0) {
                        try formatVttTime(writer, cue_start_sec);
                        try writer.writeAll(" --> ");
                        try formatVttTime(writer, cue_end_sec);
                        try writer.writeAll("\n");
                        try writer.writeAll(trimmed);
                        try writer.writeAll("\n\n");
                    }
                }
            } else if (sub.id == ebml.ID_BLOCK_GROUP) {
                var bg_rem: u64 = sub.size;
                var block_payload: ?[]u8 = null;
                defer if (block_payload) |bp| allocator.free(bp);
                var bg_duration_raw: ?u64 = null;
                var bg_track_num: ?u64 = null;
                var bg_rel_timecode: i16 = 0;

                while (bg_rem > 0) {
                    const bg_child = (try ebml.readElementHeader(r)) orelse break;
                    bg_rem -= bg_child.header_size;
                    if (bg_child.size != ebml.UNKNOWN_SIZE and bg_child.size > bg_rem) break;

                    if (bg_child.id == ebml.ID_BLOCK) {
                        if (bg_child.size < 4) {
                            try ebml.skipBytes(r, bg_child.size);
                            bg_rem -= bg_child.size;
                            continue;
                        }

                        const peek_len: usize = @intCast(@min(bg_child.size, 16));
                        var header_buf: [16]u8 = undefined;
                        try r.readSliceAll(header_buf[0..peek_len]);

                        const track_res = ebml.decodeVint(header_buf[0..peek_len]) catch {
                            try ebml.skipBytes(r, bg_child.size - peek_len);
                            bg_rem -= bg_child.size;
                            continue;
                        };
                        bg_track_num = track_res.value;
                        if (track_res.value == target_track_num) {
                            const hdr_len = track_res.len + 3;
                            if (bg_child.size >= hdr_len) {
                                bg_rel_timecode = std.mem.readInt(i16, header_buf[track_res.len..][0..2], .big);
                                const payload_len: usize = @intCast(bg_child.size - hdr_len);
                                const p_buf = try allocator.alloc(u8, payload_len);
                                errdefer allocator.free(p_buf);

                                const already_in_hdr = if (peek_len > hdr_len) peek_len - hdr_len else 0;
                                if (already_in_hdr > 0) {
                                    @memcpy(p_buf[0..already_in_hdr], header_buf[hdr_len..peek_len]);
                                }
                                const rem_to_read = payload_len - already_in_hdr;
                                if (rem_to_read > 0) {
                                    try r.readSliceAll(p_buf[already_in_hdr..]);
                                }
                                block_payload = p_buf;
                            } else {
                                try ebml.skipBytes(r, bg_child.size - peek_len);
                            }
                        } else {
                            try ebml.skipBytes(r, bg_child.size - peek_len);
                        }
                        bg_rem -= bg_child.size;
                    } else if (bg_child.id == ebml.ID_BLOCK_DURATION) {
                        bg_duration_raw = try ebml.readUint(r, bg_child.size);
                        bg_rem -= bg_child.size;
                    } else {
                        try ebml.skipBytes(r, bg_child.size);
                        bg_rem -= bg_child.size;
                    }
                }

                if (bg_track_num == target_track_num and block_payload != null) {
                    const cue_start_sec = (@as(f64, @floatFromInt(cluster_timestamp_raw)) + @as(f64, @floatFromInt(bg_rel_timecode))) * time_multiplier;
                    const cue_duration_sec = if (bg_duration_raw) |d| @as(f64, @floatFromInt(d)) * time_multiplier else 3.0;
                    const cue_end_sec = cue_start_sec + @max(0.5, cue_duration_sec);

                    if (cue_end_sec >= start_offset) {
                        text_buf.clearRetainingCapacity();
                        try cleanAssText(&text_buf, allocator, block_payload.?);
                        const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
                        if (trimmed.len > 0) {
                            try formatVttTime(writer, cue_start_sec);
                            try writer.writeAll(" --> ");
                            try formatVttTime(writer, cue_end_sec);
                            try writer.writeAll("\n");
                            try writer.writeAll(trimmed);
                            try writer.writeAll("\n\n");
                        }
                    }
                }
                cluster_rem -= sub.size;
            } else {
                if (sub.size != ebml.UNKNOWN_SIZE) {
                    try ebml.skipBytes(r, sub.size);
                    cluster_rem -= sub.size;
                }
            }
        }

        // Read next level-1 cluster element
        cluster_elem = null;
        while (true) {
            const next_elem = (try ebml.readElementHeader(r)) orelse break;
            if (next_elem.id == ebml.ID_CLUSTER) {
                cluster_elem = next_elem;
                break;
            } else if (next_elem.size != ebml.UNKNOWN_SIZE) {
                try ebml.skipBytes(r, next_elem.size);
            }
        }
    }
}

test "formatVttTime" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try formatVttTime(&aw.writer, 3661.543);
    try std.testing.expectEqualStrings("01:01:01.543", aw.written());
}

test "cleanAssText" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const raw = "Dialogue: 0,0:01:00.00,0:01:05.00,Default,,0,0,0,,{\\an8}Hello\\NWorld!";
    try cleanAssText(&out, std.testing.allocator, raw);
    try std.testing.expectEqualStrings("Hello\nWorld!", out.items);
}

test "extractMkvSubtitlesVtt from test_sync.mkv" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try extractMkvSubtitlesVtt(allocator, io, &aw.writer, "tests/test_sync.mkv", 2, 0.0);
    const vtt = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, vtt, "-->") != null);
}

