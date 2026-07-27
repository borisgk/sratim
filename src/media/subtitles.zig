const std = @import("std");
const c = @import("../core/c.zig").c;

pub const SubtitleTrack = struct {
    id: usize,
    label: []const u8,
    language: []const u8,
};

fn formatVttTime(out: *std.ArrayList(u8), allocator: std.mem.Allocator, total_seconds: f64) !void {
    const sec_val = if (total_seconds < 0) 0.0 else total_seconds;
    const total_ms: u64 = @intFromFloat(sec_val * 1000.0);
    const hours = total_ms / (3600 * 1000);
    const mins = (total_ms % (3600 * 1000)) / (60 * 1000);
    const secs = (total_ms % (60 * 1000)) / 1000;
    const ms = total_ms % 1000;

    const formatted = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, mins, secs, ms });
    defer allocator.free(formatted);
    try out.appendSlice(allocator, formatted);
}

fn parseTimestampSeconds(ts_str: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, ts_str, " \r\t");
    if (trimmed.len < 3) return null;

    var parts: [3][]const u8 = undefined;
    var num_parts: usize = 0;
    var it = std.mem.splitScalar(u8, trimmed, ':');
    while (it.next()) |p| {
        if (num_parts >= 3) break;
        parts[num_parts] = p;
        num_parts += 1;
    }

    if (num_parts < 2) return null;

    var hours: f64 = 0;
    var mins: f64 = 0;
    var secs_raw: []const u8 = "";

    if (num_parts == 3) {
        hours = std.fmt.parseFloat(f64, parts[0]) catch return null;
        mins = std.fmt.parseFloat(f64, parts[1]) catch return null;
        secs_raw = parts[2];
    } else {
        mins = std.fmt.parseFloat(f64, parts[0]) catch return null;
        secs_raw = parts[1];
    }

    var sec_buf: [32]u8 = undefined;
    if (secs_raw.len >= sec_buf.len) return null;
    @memcpy(sec_buf[0..secs_raw.len], secs_raw);
    for (sec_buf[0..secs_raw.len]) |*b| {
        if (b.* == ',') b.* = '.';
    }
    const secs = std.fmt.parseFloat(f64, sec_buf[0..secs_raw.len]) catch return null;

    return hours * 3600.0 + mins * 60.0 + secs;
}

fn isAssHeaderLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len >= 9 and std.ascii.eqlIgnoreCase(trimmed[0..9], "dialogue:")) return true;
    if (trimmed.len >= 8 and std.ascii.eqlIgnoreCase(trimmed[0..8], "comment:")) return true;

    if (std.mem.indexOf(u8, trimmed, ",Default,") != null or
        std.mem.indexOf(u8, trimmed, ",Main,") != null or
        std.mem.indexOf(u8, trimmed, ",0:00:") != null or
        std.mem.indexOf(u8, trimmed, ",0:01:") != null or
        std.mem.indexOf(u8, trimmed, ",0:02:") != null)
    {
        return true;
    }

    return false;
}

fn cleanAssText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ass_raw: []const u8) !void {
    var text = std.mem.trim(u8, ass_raw, " \t\r\n");
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
        // Form A: Dialogue: line has 9 header fields before Text. Stop searching at 9th comma!
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
        // Form B: Raw FFmpeg ASS line (ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text)
        // Stop searching at EXACTLY 8th comma! NEVER count commas in text!
        var commas: usize = 0;
        var eighth_comma_idx: ?usize = null;

        for (text, 0..) |ch, idx| {
            if (ch == ',') {
                commas += 1;
                if (commas == 8) {
                    eighth_comma_idx = idx;
                    break; // STOP AT 8TH COMMA!
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

/// Scans for external subtitle files (.srt, .vtt, .ass, .ssa) in the same directory as the media file.
pub fn scanExternalSubtitles(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]SubtitleTrack {
    var tracks: std.ArrayList(SubtitleTrack) = .empty;
    errdefer {
        for (tracks.items) |t| {
            allocator.free(t.label);
            allocator.free(t.language);
        }
        tracks.deinit(allocator);
    }

    const dir_path = std.fs.path.dirname(file_path) orelse return try tracks.toOwnedSlice(allocator);
    const stem = std.fs.path.stem(file_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return try tracks.toOwnedSlice(allocator);
    defer dir.close(io);

    var iterator = dir.iterate();
    var ext_idx: usize = 1000;

    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, stem)) continue;

        const ext = std.fs.path.extension(name);
        if (std.mem.eql(u8, ext, ".srt") or std.mem.eql(u8, ext, ".vtt") or std.mem.eql(u8, ext, ".ass") or std.mem.eql(u8, ext, ".ssa")) {
            const middle = name[stem.len .. name.len - ext.len];
            var lang: []const u8 = "";
            var label_str: []const u8 = "External Subtitle";
            var free_label = false;

            if (middle.len > 1 and middle[0] == '.') {
                lang = middle[1..];
                label_str = try std.fmt.allocPrint(allocator, "External ({s})", .{lang});
                free_label = true;
            }
            defer if (free_label) allocator.free(label_str);

            const label_dup = try allocator.dupe(u8, label_str);
            const lang_dup = try allocator.dupe(u8, lang);

            try tracks.append(allocator, .{
                .id = ext_idx,
                .label = label_dup,
                .language = lang_dup,
            });
            ext_idx += 1;
        }
    }

    return tracks.toOwnedSlice(allocator);
}

/// Reads an external subtitle file (.srt, .vtt, .ass) and converts it to WebVTT format offset by start_offset.
pub fn extractExternalSubtitleVtt(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8, target_ext_idx: usize, start_offset: f64) ![]u8 {
    const effective_offset = start_offset;
    const dir_path = std.fs.path.dirname(file_path) orelse return error.FileNotFound;
    const stem = std.fs.path.stem(file_path);

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.FileNotFound;
    defer dir.close(io);

    var iterator = dir.iterate();
    var ext_idx: usize = 1000;

    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.startsWith(u8, name, stem)) continue;

        const ext = std.fs.path.extension(name);
        if (std.mem.eql(u8, ext, ".srt") or std.mem.eql(u8, ext, ".vtt") or std.mem.eql(u8, ext, ".ass") or std.mem.eql(u8, ext, ".ssa")) {
            if (ext_idx == target_ext_idx) {
                const sub_file_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, name });
                defer allocator.free(sub_file_path);

                const file_content = std.Io.Dir.cwd().readFileAlloc(io, sub_file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch return error.ReadFileFailed;
                defer allocator.free(file_content);

                var vtt: std.ArrayList(u8) = .empty;
                errdefer vtt.deinit(allocator);
                try vtt.appendSlice(allocator, "WEBVTT\n\n");

                var line_it = std.mem.splitScalar(u8, file_content, '\n');
                var in_cue = false;
                var cue_start: f64 = 0;
                var cue_end: f64 = 0;
                var cue_text: std.ArrayList(u8) = .empty;
                defer cue_text.deinit(allocator);

                while (line_it.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, " \r\t");
                    if (std.mem.indexOf(u8, trimmed, "-->")) |arrow_idx| {
                        if (in_cue and cue_end > effective_offset and cue_text.items.len > 0) {
                            const rel_start = @max(0.0, cue_start - effective_offset);
                            const rel_end = cue_end - effective_offset;
                            try formatVttTime(&vtt, allocator, rel_start);
                            try vtt.appendSlice(allocator, " --> ");
                            try formatVttTime(&vtt, allocator, rel_end);
                            try vtt.appendSlice(allocator, "\n");
                            try vtt.appendSlice(allocator, cue_text.items);
                            try vtt.appendSlice(allocator, "\n\n");
                        }

                        const start_str = trimmed[0..arrow_idx];
                        const end_str = trimmed[arrow_idx + 3 ..];
                        if (parseTimestampSeconds(start_str)) |st| {
                            if (parseTimestampSeconds(end_str)) |et| {
                                cue_start = st;
                                cue_end = et;
                                in_cue = true;
                                cue_text.clearRetainingCapacity();
                            }
                        }
                    } else if (trimmed.len == 0 and in_cue) {
                        if (cue_end > effective_offset and cue_text.items.len > 0) {
                            const rel_start = @max(0.0, cue_start - effective_offset);
                            const rel_end = cue_end - effective_offset;
                            try formatVttTime(&vtt, allocator, rel_start);
                            try vtt.appendSlice(allocator, " --> ");
                            try formatVttTime(&vtt, allocator, rel_end);
                            try vtt.appendSlice(allocator, "\n");
                            try vtt.appendSlice(allocator, cue_text.items);
                            try vtt.appendSlice(allocator, "\n\n");
                        }
                        in_cue = false;
                    } else if (in_cue) {
                        if (cue_text.items.len > 0) try cue_text.append(allocator, '\n');
                        try cleanAssText(&cue_text, allocator, trimmed);
                    }
                }

                if (in_cue and cue_end > effective_offset and cue_text.items.len > 0) {
                    const rel_start = @max(0.0, cue_start - effective_offset);
                    const rel_end = cue_end - effective_offset;
                    try formatVttTime(&vtt, allocator, rel_start);
                    try vtt.appendSlice(allocator, " --> ");
                    try formatVttTime(&vtt, allocator, rel_end);
                    try vtt.appendSlice(allocator, "\n");
                    try vtt.appendSlice(allocator, cue_text.items);
                    try vtt.appendSlice(allocator, "\n\n");
                }

                return vtt.toOwnedSlice(allocator);
            }
            ext_idx += 1;
        }
    }

    return error.SubtitleTrackNotFound;
}

/// Native libavcodec fallback for subtitle extraction.
pub fn extractSubtitlesVttLibav(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8, stream_idx: usize, start_offset: f64) ![]u8 {
    _ = io;
    const effective_offset = start_offset;
    var fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(@ptrCast(&fmt_ctx), file_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(@ptrCast(&fmt_ctx));

    // Limit probe size/duration so find_stream_info takes < 2ms
    fmt_ctx.?.max_analyze_duration = 500000;
    fmt_ctx.?.fps_probe_size = 0;

    // Discard non-subtitle streams BEFORE calling find_stream_info
    for (0..fmt_ctx.?.nb_streams) |i| {
        if (i != stream_idx) {
            fmt_ctx.?.streams[i].*.discard = c.AVDISCARD_ALL;
        } else {
            fmt_ctx.?.streams[i].*.discard = c.AVDISCARD_NONE;
        }
    }

    if (c.avformat_find_stream_info(fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    if (stream_idx >= fmt_ctx.?.nb_streams) return error.InvalidStreamIndex;
    const stream = fmt_ctx.?.streams[stream_idx];
    if (stream.*.codecpar.*.codec_type != c.AVMEDIA_TYPE_SUBTITLE) return error.NotASubtitleStream;

    var vtt: std.ArrayList(u8) = .empty;
    errdefer vtt.deinit(allocator);
    try vtt.appendSlice(allocator, "WEBVTT\n\n");

    const codec = c.avcodec_find_decoder(stream.*.codecpar.*.codec_id);
    var dec_ctx: ?*c.AVCodecContext = null;
    if (codec != null) {
        dec_ctx = c.avcodec_alloc_context3(codec);
        if (dec_ctx != null) {
            _ = c.avcodec_parameters_to_context(dec_ctx.?, stream.*.codecpar);
            if (c.avcodec_open2(dec_ctx.?, codec, null) < 0) {
                c.avcodec_free_context(@ptrCast(&dec_ctx));
                dec_ctx = null;
            }
        }
    }
    defer if (dec_ctx != null) c.avcodec_free_context(@ptrCast(&dec_ctx));

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    const tb = stream.*.time_base;
    const tb_sec = c.av_q2d(tb);

    while (c.av_read_frame(fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);

        if (@as(usize, @intCast(pkt.*.stream_index)) != stream_idx) continue;

        var start_pts_sec: f64 = 0.0;
        const pts_val = if (pkt.*.pts != c.AV_NOPTS_VALUE) pkt.*.pts else pkt.*.dts;
        if (pts_val != c.AV_NOPTS_VALUE) {
            start_pts_sec = @as(f64, @floatFromInt(pts_val)) * tb_sec;
        }

        const duration_sec: f64 = if (pkt.*.duration > 0) @as(f64, @floatFromInt(pkt.*.duration)) * tb_sec else 3.0;

        if (dec_ctx != null) {
            var sub: c.AVSubtitle = undefined;
            @memset(std.mem.asBytes(&sub), 0);
            var got_sub: c_int = 0;

            if (c.avcodec_decode_subtitle2(dec_ctx.?, &sub, &got_sub, pkt) >= 0 and got_sub != 0) {
                defer c.avsubtitle_free(&sub);

                const sub_pts_sec: f64 = if (sub.pts != c.AV_NOPTS_VALUE)
                    @as(f64, @floatFromInt(sub.pts)) / @as(f64, @floatFromInt(c.AV_TIME_BASE))
                else
                    start_pts_sec;

                const cue_start = sub_pts_sec + (@as(f64, @floatFromInt(sub.start_display_time)) / 1000.0);
                var cue_end = sub_pts_sec + (@as(f64, @floatFromInt(sub.end_display_time)) / 1000.0);
                if (cue_end <= cue_start) {
                    cue_end = cue_start + duration_sec;
                }

                if (cue_end > effective_offset) {
                    const rel_start = @max(0.0, cue_start - effective_offset);
                    const rel_end = cue_end - effective_offset;

                    var text_buf: std.ArrayList(u8) = .empty;
                    defer text_buf.deinit(allocator);

                    for (0..sub.num_rects) |r| {
                        const rect = sub.rects[r].*;
                        if (rect.text != null) {
                            const raw_str = std.mem.span(rect.text);
                            try cleanAssText(&text_buf, allocator, raw_str);
                        } else if (rect.ass != null) {
                            const raw_str = std.mem.span(rect.ass);
                            try cleanAssText(&text_buf, allocator, raw_str);
                        }
                    }

                    const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
                    if (trimmed.len > 0) {
                        try formatVttTime(&vtt, allocator, rel_start);
                        try vtt.appendSlice(allocator, " --> ");
                        try formatVttTime(&vtt, allocator, rel_end);
                        try vtt.appendSlice(allocator, "\n");
                        try vtt.appendSlice(allocator, trimmed);
                        try vtt.appendSlice(allocator, "\n\n");
                    }
                }
                continue;
            }
        }

        if (pkt.*.size > 0 and pkt.*.data != null) {
            const raw_pkt_slice = pkt.*.data[0..@intCast(pkt.*.size)];
            const cue_start = start_pts_sec;
            const cue_end = start_pts_sec + duration_sec;

            if (cue_end > effective_offset) {
                const rel_start = @max(0.0, cue_start - effective_offset);
                const rel_end = cue_end - effective_offset;

                var text_buf: std.ArrayList(u8) = .empty;
                defer text_buf.deinit(allocator);
                try cleanAssText(&text_buf, allocator, raw_pkt_slice);

                const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
                if (trimmed.len > 0) {
                    try formatVttTime(&vtt, allocator, rel_start);
                    try vtt.appendSlice(allocator, " --> ");
                    try formatVttTime(&vtt, allocator, rel_end);
                    try vtt.appendSlice(allocator, "\n");
                    try vtt.appendSlice(allocator, trimmed);
                    try vtt.appendSlice(allocator, "\n\n");
                }
            }
        }
    }

    return vtt.toOwnedSlice(allocator);
}

/// Extracts a subtitle stream from a media file and converts it into WebVTT text format.
/// Uses ffmpeg process execution first (fastest, 100% compliant with standard WebVTT),
/// falling back to native libavcodec extraction if needed.
pub fn extractSubtitlesVtt(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8, stream_idx: usize, start_offset: f64) ![]u8 {
    if (stream_idx >= 1000) {
        return extractExternalSubtitleVtt(allocator, io, file_path, stream_idx, start_offset);
    }

    var map_buf: [32]u8 = undefined;
    const map_arg = std.fmt.bufPrint(&map_buf, "0:{d}", .{stream_idx}) catch "";

    var ss_buf: [32]u8 = undefined;
    const ss_arg = if (start_offset > 0)
        (std.fmt.bufPrint(&ss_buf, "{d:.3}", .{start_offset}) catch "0")
    else
        "0";

    const ffmpeg_bins = [_][]const u8{
        "/opt/homebrew/bin/ffmpeg",
        "/usr/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "ffmpeg",
    };

    for (ffmpeg_bins) |bin| {
        if (map_arg.len == 0) break;
        const result = if (start_offset > 0)
            std.process.run(allocator, io, .{
                .argv = &[_][]const u8{
                    bin,
                    "-v",
                    "quiet",
                    "-ss",
                    ss_arg,
                    "-i",
                    file_path,
                    "-map",
                    map_arg,
                    "-f",
                    "webvtt",
                    "-",
                },
            }) catch continue
        else
            std.process.run(allocator, io, .{
                .argv = &[_][]const u8{
                    bin,
                    "-v",
                    "quiet",
                    "-i",
                    file_path,
                    "-map",
                    map_arg,
                    "-f",
                    "webvtt",
                    "-",
                },
            }) catch continue;

        allocator.free(result.stderr);

        if (result.stdout.len > 0 and std.mem.startsWith(u8, result.stdout, "WEBVTT")) {
            return result.stdout;
        }
        allocator.free(result.stdout);
    }

    return extractSubtitlesVttLibav(allocator, io, file_path, stream_idx, start_offset);
}
