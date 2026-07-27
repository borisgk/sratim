const std = @import("std");
const c = @import("../core/c.zig").c;

/// Returns the actual keyframe PTS for a given seek position.
/// Opens the file, seeks to start_time with AVSEEK_FLAG_BACKWARD,
/// reads one packet, and returns its DTS/PTS in seconds.
/// This is lightweight: no avformat_find_stream_info, just header + seek + one read.
pub fn getKeyframePts(file_path: []const u8, start_time: f64) f64 {
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

    while (c.av_read_frame(fmt_ctx.?, pkt.?) >= 0) {
        defer c.av_packet_unref(pkt.?);
        const in_tb = fmt_ctx.?.streams[@intCast(pkt.?.stream_index)].*.time_base;
        const dts = if (pkt.?.dts != c.AV_NOPTS_VALUE) pkt.?.dts else pkt.?.pts;
        if (dts != c.AV_NOPTS_VALUE) {
            const av_tb = c.AVRational{ .num = 1, .den = c.AV_TIME_BASE };
            const pts_us = c.av_rescale_q(dts, in_tb, av_tb);
            return @as(f64, @floatFromInt(pts_us)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
        }
    }

    return start_time;
}
