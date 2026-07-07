const std = @import("std");
const c = @import("c.zig").c;

const transcoder = @import("transcoder.zig");

/// Context passed to the custom FFmpeg AVIO writer.
/// Used to bridge FFmpeg's blocking writes into Zig's asynchronous-capable standard HTTP body writer.
pub const HttpStreamContext = struct {
    writer: *std.http.BodyWriter,
    has_error: bool = false,
};

/// Custom I/O callback for FFmpeg.
/// Whenever FFmpeg needs to write muxed data (e.g. MP4 chunks), it calls this function.
/// This function writes directly to the HTTP response stream.
pub fn write_packet(ptr: ?*anyopaque, buf: [*c]const u8, buf_size: c_int) callconv(.c) c_int {
    var ctx = @as(*HttpStreamContext, @ptrCast(@alignCast(ptr.?)));
    if (ctx.has_error) return -1;
    
    // We use writeAll because the stream is chunked and we need everything to flush properly
    ctx.writer.writer.writeAll(buf[0..@intCast(buf_size)]) catch {
        ctx.has_error = true;
        return -1; // Notify FFmpeg that writing failed
    };
    return buf_size;
}

/// The main streaming pipeline.
/// Opens an input media file (e.g., MKV), reads streams, dynamically transcodes incompatible audio to AAC,
/// remuxes video natively (e.g., H.264), and pipes the fragmented MP4 output over HTTP.
pub fn streamMedia(file_path: []const u8, start_time: f64, http_ctx: *HttpStreamContext) !void {
    _ = c.avformat_network_init();
    defer { _ = c.avformat_network_deinit(); }

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    const c_file_path = try std.heap.c_allocator.dupeZ(u8, file_path);
    defer std.heap.c_allocator.free(c_file_path);

    if (c.avformat_open_input(@ptrCast(&in_fmt_ctx), c_file_path.ptr, null, null) < 0) return error.OpenInputFailed;
    defer c.avformat_close_input(@ptrCast(&in_fmt_ctx));

    if (c.avformat_find_stream_info(in_fmt_ctx, null) < 0) return error.StreamInfoFailed;

    const out_fmt = c.av_guess_format("mp4", null, null);
    if (out_fmt == null) return error.OutputFormatFailed;

    var out_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_alloc_output_context2(@ptrCast(&out_fmt_ctx), out_fmt, null, null) < 0) return error.AllocOutputFailed;
    defer c.avformat_free_context(out_fmt_ctx);

    var video_in_idx: c_int = -1;
    var audio_in_idx: c_int = -1;
    var video_out_idx: c_int = -1;
    var audio_out_idx: c_int = -1;
    var audio_tr: ?*transcoder.AudioTranscoder = null;
    defer if (audio_tr) |tr| tr.deinit();

    const in_ctx = in_fmt_ctx.?;
    const out_ctx = out_fmt_ctx.?;

    for (0..@intCast(in_ctx.*.nb_streams)) |i| {
        const stream = in_ctx.*.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO and video_in_idx < 0) {
            video_in_idx = @intCast(i);
            const out_stream = c.avformat_new_stream(out_ctx, null);
            if (c.avcodec_parameters_copy(out_stream.*.codecpar, stream.*.codecpar) < 0) return error.CodecCopyFailed;
            out_stream.*.codecpar.*.codec_tag = 0; // Let the muxer choose the tag based on codec
            video_out_idx = @intCast(out_ctx.*.nb_streams - 1);
        } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO and audio_in_idx < 0) {
            audio_in_idx = @intCast(i);
            const out_stream = c.avformat_new_stream(out_ctx, null);
            
            if (stream.*.codecpar.*.codec_id != c.AV_CODEC_ID_AAC) {
                // Not AAC, spin up the transcoder
                audio_tr = try transcoder.AudioTranscoder.init(stream, out_stream);
            } else {
                // Directly copy AAC stream
                if (c.avcodec_parameters_copy(out_stream.*.codecpar, stream.*.codecpar) < 0) return error.CodecCopyFailed;
                out_stream.*.codecpar.*.codec_tag = 0;
            }
            audio_out_idx = @intCast(out_ctx.*.nb_streams - 1);
        }
    }

    const avio_buf_size = 32768;
    const avio_buf = c.av_malloc(avio_buf_size) orelse return error.OutOfMemory;
    defer c.av_free(avio_buf);
    
    out_ctx.*.pb = c.avio_alloc_context(
        @ptrCast(avio_buf),
        avio_buf_size,
        1, // write_flag
        @ptrCast(http_ctx), // opaque
        null, // read_packet
        write_packet, // write_packet callback
        null, // seek
    ) orelse return error.AvioContextFailed;
    defer c.avio_context_free(@ptrCast(&out_ctx.*.pb));

    // movflags: fragmented mp4 configuration
    var dict: ?*c.AVDictionary = null;
    _ = c.av_dict_set(&dict, "movflags", "frag_keyframe+empty_moov+default_base_moof", 0);
    defer c.av_dict_free(@ptrCast(&dict));

    if (c.avformat_write_header(out_ctx, &dict) < 0) return error.WriteHeaderFailed;

    // Fast-seek to requested timestamp
    if (start_time > 0) {
        const start_ts = @as(i64, @intFromFloat(start_time * c.AV_TIME_BASE));
        if (c.av_seek_frame(in_ctx, -1, start_ts, c.AVSEEK_FLAG_BACKWARD) < 0) {
            std.debug.print("Seek failed for {}s\n", .{start_time});
        }
    }

    var packet = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&packet));

    // Demux and remux loop
    while (c.av_read_frame(in_ctx, packet) >= 0) {
        // Fallback calculation for missing DTS/PTS caused by `av_seek_frame` ignoring pre-roll frames
        if (packet.*.dts == c.AV_NOPTS_VALUE and packet.*.pts != c.AV_NOPTS_VALUE) {
            packet.*.dts = packet.*.pts - if (packet.*.duration > 0) packet.*.duration else 0;
        } else if (packet.*.pts == c.AV_NOPTS_VALUE and packet.*.dts != c.AV_NOPTS_VALUE) {
            packet.*.pts = packet.*.dts + if (packet.*.duration > 0) packet.*.duration else 0;
        }

        if (packet.*.stream_index == video_in_idx) {
            packet.*.stream_index = video_out_idx;
            c.av_packet_rescale_ts(packet, in_ctx.*.streams[@intCast(video_in_idx)].*.time_base, out_ctx.*.streams[@intCast(video_out_idx)].*.time_base);
            packet.*.pos = -1;
            _ = c.av_interleaved_write_frame(out_ctx, packet);
        } else if (packet.*.stream_index == audio_in_idx) {
            if (audio_tr) |tr| {
                tr.transcodePacket(packet, out_ctx, audio_out_idx) catch {};
            } else {
                packet.*.stream_index = audio_out_idx;
                c.av_packet_rescale_ts(packet, in_ctx.*.streams[@intCast(audio_in_idx)].*.time_base, out_ctx.*.streams[@intCast(audio_out_idx)].*.time_base);
                packet.*.pos = -1;
                _ = c.av_interleaved_write_frame(out_ctx, packet);
            }
        }
        c.av_packet_unref(packet);
    }

    _ = c.av_write_trailer(out_ctx);

    if (http_ctx.has_error) {
        return error.ConnectionDropped;
    }
}
