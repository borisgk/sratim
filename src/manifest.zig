const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/dict.h");
});

fn appendPrint(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const str = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(str);
    try list.appendSlice(allocator, str);
}

fn formatDuration(allocator: std.mem.Allocator, duration_seconds: f64) ![]const u8 {
    const total_seconds: u64 = @intFromFloat(duration_seconds);
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    return std.fmt.allocPrint(allocator, "PT{d}H{d}M{d}S", .{ hours, minutes, seconds });
}

pub const MpdResult = struct {
    xml: []const u8,
    splits: []i64,
};

pub fn generateMpd(allocator: std.mem.Allocator, path: []const u8, url_file_param: []const u8) !MpdResult {
    var fmt_ctx: ?*c.AVFormatContext = null;
    
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    
    if (c.avformat_open_input(&fmt_ctx, path_z, null, null) != 0) {
        return error.OpenInputFailed;
    }
    defer c.avformat_close_input(&fmt_ctx);

    if (c.avformat_find_stream_info(fmt_ctx, null) < 0) {
        return error.FindStreamInfoFailed;
    }

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const duration_sec = if (fmt_ctx.?.*.duration != c.AV_NOPTS_VALUE) 
                         @as(f64, @floatFromInt(fmt_ctx.?.*.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE))
                         else 0.0;
                         
    const duration_str = try formatDuration(allocator, duration_sec);
    defer allocator.free(duration_str);

    // Build splits array from video stream
    var splits: std.ArrayList(i64) = .empty;
    defer splits.deinit(allocator);

    var video_stream: ?*c.AVStream = null;
    for (0..@intCast(fmt_ctx.?.*.nb_streams)) |j| {
        const st = fmt_ctx.?.*.streams[j];
        if (st.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
            video_stream = st;
            break;
        }
    }

    const AVIndexEntry = extern struct {
        pos: i64,
        timestamp: i64,
        flags_and_size: i32,
        min_distance: i32,
    };

    if (video_stream) |v_st| {
        try splits.append(allocator, 0);
        
        const nb_entries = c.avformat_index_get_entries_count(v_st);
        const target_duration_v = @divTrunc(10 * @as(i64, @intCast(v_st.*.time_base.den)), @as(i64, @intCast(v_st.*.time_base.num)));
        
        if (nb_entries > 1) {
            var start_ts: i64 = 0;
            
            for (0..@intCast(nb_entries)) |k| {
                const raw_entry = c.avformat_index_get_entry(v_st, @intCast(k));
                if (raw_entry != null) {
                    const entry: *const AVIndexEntry = @ptrCast(@alignCast(raw_entry));
                    const curr_ts = entry.timestamp;
                    if (curr_ts - start_ts >= target_duration_v) {
                        try splits.append(allocator, c.av_rescale_q(curr_ts, v_st.*.time_base, c.av_get_time_base_q()));
                        start_ts = curr_ts;
                    }
                }
            }
        } else {
            // Fallback for missing index: Scan the file for keyframes
            std.debug.print("Scanning file for keyframes as index is missing...\n", .{});
            var pkt: ?*c.AVPacket = c.av_packet_alloc();
            defer c.av_packet_free(&pkt);
            
            var start_ts: i64 = 0;
            while (c.av_read_frame(fmt_ctx, pkt) >= 0) {
                defer c.av_packet_unref(pkt);
                if (pkt.?.*.stream_index == v_st.*.index) {
                    if ((pkt.?.*.flags & c.AV_PKT_FLAG_KEY) != 0) {
                        var curr_ts = pkt.?.*.pts;
                        if (curr_ts == c.AV_NOPTS_VALUE) curr_ts = pkt.?.*.dts;
                        
                        if (curr_ts != c.AV_NOPTS_VALUE) {
                            if (curr_ts - start_ts >= target_duration_v) {
                                try splits.append(allocator, c.av_rescale_q(curr_ts, v_st.*.time_base, c.av_get_time_base_q()));
                                start_ts = curr_ts;
                            }
                        }
                    }
                }
            }
        }
    }
    
    if (fmt_ctx.?.*.duration != c.AV_NOPTS_VALUE) {
        try splits.append(allocator, fmt_ctx.?.*.duration);
    }


    // Helper function for building timeline string per timescale
    const Builder = struct {
        fn buildTimelineStr(a: std.mem.Allocator, s: *std.ArrayList(i64), ts: u32) ![]const u8 {
            var timeline_list: std.ArrayList(u8) = .empty;
            try appendPrint(a, &timeline_list, "          <SegmentTimeline>\n", .{});
            if (s.items.len > 1) {
                const first_t = c.av_rescale_q(s.items[0], c.av_get_time_base_q(), .{ .num = 1, .den = @as(c_int, @intCast(ts)) });
                try appendPrint(a, &timeline_list, "            <S t=\"{d}\" ", .{ first_t });
                for (1..s.items.len) |k| {
                    const prev = c.av_rescale_q(s.items[k-1], c.av_get_time_base_q(), .{ .num = 1, .den = @as(c_int, @intCast(ts)) });
                    const curr = c.av_rescale_q(s.items[k], c.av_get_time_base_q(), .{ .num = 1, .den = @as(c_int, @intCast(ts)) });
                    const duration = curr - prev;
                    if (k == 1) {
                        try appendPrint(a, &timeline_list, "d=\"{d}\" />\n", .{ duration });
                    } else {
                        try appendPrint(a, &timeline_list, "            <S d=\"{d}\" />\n", .{ duration });
                    }
                }
            }
            try appendPrint(a, &timeline_list, "          </SegmentTimeline>", .{});
            return timeline_list.toOwnedSlice(a);
        }
    };

    try appendPrint(allocator, &list,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" mediaPresentationDuration="{s}">
        \\  <Period>
        \\
    , .{ duration_str });

    const num_streams = fmt_ctx.?.*.nb_streams;
    var i: usize = 0;
    var audio_index: usize = 0;
    
    while (i < num_streams) : (i += 1) {
        const stream = fmt_ctx.?.*.streams[i];
        const codec_par = stream.*.codecpar;
        const codec_type = codec_par.*.codec_type;
        const codec_id = codec_par.*.codec_id;
        
        var codec_str: []const u8 = "unknown";
        if (codec_id == c.AV_CODEC_ID_H264) {
            codec_str = "avc1.4d401e";
        } else if (codec_id == c.AV_CODEC_ID_HEVC) {
            codec_str = "hev1.1.6.L93.B0";
        } else if (codec_id == c.AV_CODEC_ID_AAC) {
            codec_str = "mp4a.40.2";
        } else if (codec_id == c.AV_CODEC_ID_AC3) {
            codec_str = "ac-3";
        } else if (codec_id == c.AV_CODEC_ID_EAC3) {
            codec_str = "ec-3";
        }
        
        const bandwidth = if (codec_par.*.bit_rate > 0) codec_par.*.bit_rate else 5000000;

        if (codec_type == c.AVMEDIA_TYPE_VIDEO) {
            const video_timescale: u32 = 90000;
            const timeline_str = try Builder.buildTimelineStr(allocator, &splits, video_timescale);
            defer allocator.free(timeline_str);
            try appendPrint(allocator, &list,
                \\    <AdaptationSet mimeType="video/mp4" codecs="{s}">
                \\      <Representation id="video" bandwidth="{d}">
                \\        <SegmentTemplate timescale="{d}" initialization="/api/stream/{s}/video/init.mp4" media="/api/stream/{s}/video/chunk_$Number$.m4s" startNumber="1">
                \\{s}
                \\        </SegmentTemplate>
                \\      </Representation>
                \\    </AdaptationSet>
                \\
            , .{ codec_str, bandwidth, video_timescale, url_file_param, url_file_param, timeline_str });
        } else if (codec_type == c.AVMEDIA_TYPE_AUDIO) {
            const lang_dict = c.av_dict_get(stream.*.metadata, "language", null, 0);
            const lang = if (lang_dict != null) std.mem.span(lang_dict.?.*.value) else "en";

            const audio_timescale: u32 = @intCast(codec_par.*.sample_rate);
            const timeline_str = try Builder.buildTimelineStr(allocator, &splits, audio_timescale);
            defer allocator.free(timeline_str);

            try appendPrint(allocator, &list,
                \\    <AdaptationSet mimeType="audio/mp4" codecs="{s}" lang="{s}">
                \\      <Representation id="audio_{d}" bandwidth="{d}">
                \\        <SegmentTemplate timescale="{d}" initialization="/api/stream/{s}/audio/{d}/init.mp4" media="/api/stream/{s}/audio/{d}/chunk_$Number$.m4s" startNumber="1">
                \\{s}
                \\        </SegmentTemplate>
                \\      </Representation>
                \\    </AdaptationSet>
                \\
            , .{ codec_str, lang, audio_index, bandwidth, audio_timescale, url_file_param, audio_index, url_file_param, audio_index, timeline_str });
            audio_index += 1;
        }
    }

    try appendPrint(allocator, &list, "  </Period>\n</MPD>\n", .{});
    
    return MpdResult{
        .xml = try list.toOwnedSlice(allocator),
        .splits = try splits.toOwnedSlice(allocator),
    };
}
