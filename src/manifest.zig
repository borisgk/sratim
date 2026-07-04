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

pub fn generateMpd(allocator: std.mem.Allocator, file_path: []const u8, url_file_param: []const u8) ![]const u8 {
    var fmt_ctx: ?*c.AVFormatContext = null;
    
    const path_z = try allocator.dupeZ(u8, file_path);
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
            try appendPrint(allocator, &list,
                \\    <AdaptationSet mimeType="video/mp4" codecs="{s}">
                \\      <Representation id="video" bandwidth="{d}">
                \\        <SegmentTemplate 
                \\             initialization="/api/stream/{s}/video/init.mp4" 
                \\             media="/api/stream/{s}/video/chunk_$Number$.m4s" 
                \\             startNumber="1" duration="10" timescale="1"/>
                \\      </Representation>
                \\    </AdaptationSet>
                \\
            , .{ codec_str, bandwidth, url_file_param, url_file_param });
        } else if (codec_type == c.AVMEDIA_TYPE_AUDIO) {
            const lang_dict = c.av_dict_get(stream.*.metadata, "language", null, 0);
            const lang = if (lang_dict != null) std.mem.span(lang_dict.?.*.value) else "en";

            try appendPrint(allocator, &list,
                \\    <AdaptationSet mimeType="audio/mp4" codecs="{s}" lang="{s}">
                \\      <Representation id="audio_{d}" bandwidth="{d}">
                \\        <SegmentTemplate 
                \\             initialization="/api/stream/{s}/audio/{d}/init.mp4" 
                \\             media="/api/stream/{s}/audio/{d}/chunk_$Number$.m4s" 
                \\             startNumber="1" duration="10" timescale="1"/>
                \\      </Representation>
                \\    </AdaptationSet>
                \\
            , .{ codec_str, lang, audio_index, bandwidth, url_file_param, audio_index, url_file_param, audio_index });
            audio_index += 1;
        }
    }

    try list.appendSlice(allocator, 
        \\  </Period>
        \\</MPD>
    );

    return list.toOwnedSlice(allocator);
}
