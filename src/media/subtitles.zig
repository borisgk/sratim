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

/// Native libavcodec / libavformat subtitle extraction.
pub fn extractSubtitlesVtt(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8, stream_idx: usize, start_offset: f64) ![]u8 {
    _ = io;
    var fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(@ptrCast(&fmt_ctx), file_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(@ptrCast(&fmt_ctx));

    fmt_ctx.?.max_analyze_duration = 500000;
    fmt_ctx.?.fps_probe_size = 0;

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

    if (start_offset > 0) {
        const start_ts = @as(i64, @intFromFloat(start_offset * c.AV_TIME_BASE));
        _ = c.av_seek_frame(fmt_ctx.?, -1, start_ts, c.AVSEEK_FLAG_BACKWARD);
    }

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

    var global_start_time: f64 = std.math.nan(f64);

    while (c.av_read_frame(fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);

        if (std.math.isNan(global_start_time)) {
            const p_dts = if (pkt.*.dts != c.AV_NOPTS_VALUE) pkt.*.dts else pkt.*.pts;
            if (p_dts != c.AV_NOPTS_VALUE) {
                const p_tb = fmt_ctx.?.streams[@intCast(pkt.*.stream_index)].*.time_base;
                global_start_time = @as(f64, @floatFromInt(p_dts)) * c.av_q2d(p_tb);
            } else {
                global_start_time = 0.0; // fallback if no pts/dts
            }
        }

        const base_offset = if (std.math.isNan(global_start_time)) 0.0 else global_start_time;

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
            sub.pts = c.AV_NOPTS_VALUE; // Explicitly set to NOPTS to detect if decoder sets it
            var got_sub: c_int = 0;

            if (c.avcodec_decode_subtitle2(dec_ctx.?, &sub, &got_sub, pkt) >= 0 and got_sub != 0) {
                defer c.avsubtitle_free(&sub);

                var exact_pts_sec = start_pts_sec;
                if (sub.pts != c.AV_NOPTS_VALUE) {
                    exact_pts_sec = @as(f64, @floatFromInt(sub.pts)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
                }

                const cue_start = exact_pts_sec + (@as(f64, @floatFromInt(sub.start_display_time)) / 1000.0);
                var cue_end = exact_pts_sec + (@as(f64, @floatFromInt(sub.end_display_time)) / 1000.0);
                if (cue_end <= cue_start) {
                    cue_end = cue_start + duration_sec;
                }

                if (cue_end > base_offset) {
                    const rel_start = @max(0.0, cue_start - base_offset);
                    const rel_end = cue_end - base_offset;

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

            if (cue_end > base_offset) {
                const rel_start = @max(0.0, cue_start - base_offset);
                const rel_end = cue_end - base_offset;

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
