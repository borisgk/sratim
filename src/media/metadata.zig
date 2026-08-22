const std = @import("std");
const c = @import("../core/c.zig").c;
const native_metadata = @import("native/metadata.zig");
const config_mod = @import("../config.zig");

/// Returns the actual keyframe PTS for a given seek position.
pub fn getKeyframePts(io: std.Io, file_path: []const u8, start_time: f64, audio_idx_requested: c_int, mode: config_mod.EngineMode) f64 {
    if (mode == .native) {
        if (native_metadata.getKeyframePts(io, file_path, start_time)) |pts| {
            return pts;
        } else |_| {
            return getKeyframePtsFfmpeg(file_path, start_time, audio_idx_requested);
        }
    }
    return getKeyframePtsFfmpeg(file_path, start_time, audio_idx_requested);
}

pub fn getKeyframePtsFfmpeg(file_path: []const u8, start_time: f64, audio_idx_requested: c_int) f64 {
    const c_path = std.heap.c_allocator.dupeZ(u8, file_path) catch return start_time;
    defer std.heap.c_allocator.free(c_path);

    var fmt_ctx: ?*c.AVFormatContext = c.avformat_alloc_context();
    if (fmt_ctx != null) {
        fmt_ctx.?.flags |= c.AVFMT_FLAG_GENPTS;
    }
    if (c.avformat_open_input(@ptrCast(&fmt_ctx), c_path.ptr, null, null) < 0) return start_time;
    defer c.avformat_close_input(@ptrCast(&fmt_ctx));

    _ = c.avformat_find_stream_info(fmt_ctx.?, null);

    if (start_time > 0) {
        const start_ts = @as(i64, @intFromFloat(start_time * c.AV_TIME_BASE));
        _ = c.av_seek_frame(fmt_ctx.?, -1, start_ts, c.AVSEEK_FLAG_BACKWARD);
    }

    var pkt: ?*c.AVPacket = c.av_packet_alloc();
    if (pkt == null) return start_time;
    defer c.av_packet_free(&pkt);

    var video_in_idx: c_int = -1;
    var audio_in_idx: c_int = -1;

    for (0..fmt_ctx.?.nb_streams) |i| {
        const stream = fmt_ctx.?.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO and video_in_idx < 0) {
            video_in_idx = @intCast(i);
        } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            if (audio_idx_requested < 0 and audio_in_idx < 0) {
                audio_in_idx = @intCast(i);
            } else if (audio_idx_requested == @as(c_int, @intCast(i))) {
                audio_in_idx = @intCast(i);
            }
        }
    }

    var min_dts_sec: f64 = -1.0;
    var packets_read: usize = 0;

    while (c.av_read_frame(fmt_ctx.?, pkt.?) >= 0) {
        defer c.av_packet_unref(pkt.?);
        const stream_idx = @as(c_int, @intCast(pkt.?.stream_index));
        
        if (stream_idx != video_in_idx and stream_idx != audio_in_idx) {
            continue;
        }

        const stream = fmt_ctx.?.streams[@intCast(pkt.?.stream_index)];
        const in_tb = stream.*.time_base;
        const dts = if (pkt.?.dts != c.AV_NOPTS_VALUE) pkt.?.dts else pkt.?.pts;
        if (dts != c.AV_NOPTS_VALUE) {
            const av_tb = c.AVRational{ .num = 1, .den = c.AV_TIME_BASE };
            const pts_us = c.av_rescale_q(dts, in_tb, av_tb);
            const ts_sec = @as(f64, @floatFromInt(pts_us)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
            if (min_dts_sec < 0 or ts_sec < min_dts_sec) {
                min_dts_sec = ts_sec;
            }
        }
        packets_read += 1;
        if (packets_read >= 50) break;
    }

    if (min_dts_sec >= 0) {
        return min_dts_sec;
    }
    return start_time;
}
