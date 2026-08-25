const std = @import("std");
const c = @import("../core/c.zig").c;
const streamer = @import("streamer.zig");
const native_subtitles = @import("native/subtitles.zig");
const config_mod = @import("../config.zig");


pub const SubtitleTrack = struct {
    id: usize,
    label: []const u8,
    language: []const u8,
};

fn formatVttTime(writer: anytype, total_seconds: f64) !void {
    const sec_val = if (total_seconds < 0) 0.0 else total_seconds;
    const total_ms: u64 = @intFromFloat(sec_val * 1000.0);
    const hours = total_ms / (3600 * 1000);
    const mins = (total_ms % (3600 * 1000)) / (60 * 1000);
    const secs = (total_ms % (60 * 1000)) / 1000;
    const ms = total_ms % 1000;

    try writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, mins, secs, ms });
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

/// Dispatches subtitle extraction based on configured EngineMode.
/// When mode is .native, uses pure Zig extractors without falling back to FFmpeg.
pub fn extractSubtitlesVtt(allocator: std.mem.Allocator, io: std.Io, writer: anytype, file_path: [:0]const u8, stream_idx: usize, start_offset: f64, mode: config_mod.EngineMode) !void {
    if (mode == .native) {
        native_subtitles.extractNativeSubtitlesVtt(allocator, io, writer, file_path, stream_idx, start_offset) catch |err| {
            if (err == error.WriteFailed or err == error.BrokenPipe or err == error.ConnectionResetByPeer or err == error.NotOpenForWriting) {
                return err;
            }
            std.debug.print("Native subtitle extraction failed: {}\n", .{err});
            return err;
        };
        return;
    }
    return extractSubtitlesVttFfmpeg(allocator, io, writer, file_path, stream_idx, start_offset);
}

/// Native libavcodec / libavformat subtitle extraction directly to an HTTP or string writer.
pub fn extractSubtitlesVttFfmpeg(allocator: std.mem.Allocator, io: std.Io, writer: anytype, file_path: [:0]const u8, stream_idx: usize, start_offset: f64) !void {
    _ = io;
    
    std.debug.print("Starting FFmpeg subtitle extraction for {s}, stream_idx: {}, start_offset: {d}\n", .{file_path, stream_idx, start_offset});

    var opts: ?*c.AVDictionary = null;
    _ = c.av_dict_set(&opts, "buffer_size", "524288", 0);
    _ = c.av_dict_set(&opts, "probesize", "1048576", 0);
    _ = c.av_dict_set(&opts, "analyzeduration", "1000000", 0);
    defer c.av_dict_free(@ptrCast(&opts));

    var fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(@ptrCast(&fmt_ctx), file_path.ptr, null, &opts) < 0) return error.OpenFailed;
    defer c.avformat_close_input(@ptrCast(&fmt_ctx));

    fmt_ctx.?.max_analyze_duration = 1000000;
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

    if (start_offset > 0.0) {
        const seek_pts = @as(i64, @intFromFloat(@max(0.0, start_offset - 30.0) * c.AV_TIME_BASE));
        _ = c.av_seek_frame(fmt_ctx.?, -1, seek_pts, c.AVSEEK_FLAG_BACKWARD);
    }

    try writer.writeAll("WEBVTT\n\n");

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
        std.Thread.yield() catch {};

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

                const cue_start = start_pts_sec + (@as(f64, @floatFromInt(sub.start_display_time)) / 1000.0);
                var cue_end = start_pts_sec + (@as(f64, @floatFromInt(sub.end_display_time)) / 1000.0);
                if (cue_end <= cue_start) {
                    cue_end = cue_start + duration_sec;
                }

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
                    try formatVttTime(writer, cue_start);
                    try writer.writeAll(" --> ");
                    try formatVttTime(writer, cue_end);
                    try writer.writeAll("\n");
                    try writer.writeAll(trimmed);
                    try writer.writeAll("\n\n");
                }
                continue;
            }
            continue;
        }

        if (pkt.*.size > 0 and pkt.*.data != null) {
            const raw_pkt_slice = pkt.*.data[0..@intCast(pkt.*.size)];
            const cue_start = start_pts_sec;
            const cue_end = start_pts_sec + duration_sec;

            var text_buf: std.ArrayList(u8) = .empty;
            defer text_buf.deinit(allocator);
            try cleanAssText(&text_buf, allocator, raw_pkt_slice);

            const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
            if (trimmed.len > 0) {
                try formatVttTime(writer, cue_start);
                try writer.writeAll(" --> ");
                try formatVttTime(writer, cue_end);
                try writer.writeAll("\n");
                try writer.writeAll(trimmed);
                try writer.writeAll("\n\n");
            }
        }
    }
}

test "extractSubtitlesVtt native vs ffmpeg on MKV and MP4" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Test native mode on MP4
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_subs.mp4", 2, 0.0, .native);
        const vtt = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
        try std.testing.expect(std.mem.indexOf(u8, vtt, "Hello MP4 Subtitles!") != null);
    }

    // 2. Test ffmpeg mode on MP4
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_subs.mp4", 2, 0.0, .ffmpeg);
        const vtt = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
        try std.testing.expect(std.mem.indexOf(u8, vtt, "Hello MP4 Subtitles!") != null);
    }

    // 3. Test native mode on MKV
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_sync.mkv", 2, 0.0, .native);
        const vtt = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
        try std.testing.expect(std.mem.indexOf(u8, vtt, "SRT: 1.0s to 3.0s") != null);
    }

    // 4. Test ffmpeg mode on MKV
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_sync.mkv", 2, 0.0, .ffmpeg);
        const vtt = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
        try std.testing.expect(std.mem.indexOf(u8, vtt, "SRT: 1.0s to 3.0s") != null);
    }

    // 5. Test strict error handling in native mode (invalid stream index fails without falling back)
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const res = extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_subs.mp4", 99, 0.0, .native);
        try std.testing.expectError(error.NoSubtitleStreamsFound, res);
    }
}
