const std = @import("std");
const c = @import("../core/c.zig").c;

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
pub fn streamMedia(file_path: []const u8, start_time: f64, audio_idx_requested: c_int, http_ctx: *HttpStreamContext) !void {
    var in_fmt_ctx: ?*c.AVFormatContext = c.avformat_alloc_context();
    if (in_fmt_ctx != null) {
        in_fmt_ctx.?.flags |= c.AVFMT_FLAG_GENPTS;
    }
    const c_file_path = try std.heap.c_allocator.dupeZ(u8, file_path);
    defer std.heap.c_allocator.free(c_file_path);

    if (c.avformat_open_input(@ptrCast(&in_fmt_ctx), c_file_path.ptr, null, null) < 0) return error.OpenInputFailed;
    defer c.avformat_close_input(@ptrCast(&in_fmt_ctx));

    const in_ctx = in_fmt_ctx.?;


    if (c.avformat_find_stream_info(in_ctx, null) < 0) return error.StreamInfoFailed;

    const out_fmt = c.av_guess_format("mp4", null, null);
    if (out_fmt == null) return error.OutputFormatFailed;

    var out_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_alloc_output_context2(@ptrCast(&out_fmt_ctx), out_fmt, null, null) < 0) return error.AllocOutputFailed;

    var avio_buf: ?*anyopaque = null;
    defer {
        // Retrieve pb pointer before context gets freed
        const pb_ptr = if (out_fmt_ctx) |ctx| ctx.*.pb else null;
        
        // 1. Free the output format context first
        if (out_fmt_ctx) |ctx| {
            c.avformat_free_context(ctx);
        }
        
        // 2. Free the avio buffer second
        if (avio_buf) |buf| {
            c.av_free(buf);
        }
        
        // 3. Free the AVIOContext last
        if (pb_ptr) |pb| {
            var temp_pb = pb;
            c.avio_context_free(@ptrCast(&temp_pb));
        }
    }

    var video_in_idx: c_int = -1;
    var audio_in_idx: c_int = -1;
    var video_out_idx: c_int = -1;
    var audio_out_idx: c_int = -1;
    var audio_tr: ?*transcoder.AudioTranscoder = null;
    defer if (audio_tr) |tr| tr.deinit();

    const out_ctx = out_fmt_ctx.?;

    for (0..@intCast(in_ctx.*.nb_streams)) |i| {
        const stream = in_ctx.*.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO and video_in_idx < 0) {
            video_in_idx = @intCast(i);
            const out_stream = c.avformat_new_stream(out_ctx, null);
            if (c.avcodec_parameters_copy(out_stream.*.codecpar, stream.*.codecpar) < 0) return error.CodecCopyFailed;
            if (out_stream.*.codecpar.*.codec_id == c.AV_CODEC_ID_HEVC) {
                out_stream.*.codecpar.*.codec_tag = c.MKTAG('h', 'v', 'c', '1');
            } else if (out_stream.*.codecpar.*.codec_id == c.AV_CODEC_ID_AV1) {
                out_stream.*.codecpar.*.codec_tag = c.MKTAG('a', 'v', '0', '1');
            } else if (out_stream.*.codecpar.*.codec_id == c.AV_CODEC_ID_VP9) {
                out_stream.*.codecpar.*.codec_tag = c.MKTAG('v', 'p', '0', '9');
            } else {
                out_stream.*.codecpar.*.codec_tag = 0; // Let the muxer choose the tag based on codec
            }
            video_out_idx = @intCast(out_ctx.*.nb_streams - 1);
        } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO and audio_in_idx < 0) {
            // Pick this track if it matches the requested one, or if no specific track was requested (fallback to first)
            if (audio_idx_requested < 0 or audio_idx_requested == i) {
                audio_in_idx = @intCast(i);
                const out_stream = c.avformat_new_stream(out_ctx, null);
                
                if (stream.*.codecpar.*.codec_id != c.AV_CODEC_ID_AAC) {
                    // Not AAC, spin up the transcoder
                    audio_tr = try transcoder.AudioTranscoder.init(stream, out_stream, start_time);
                } else {
                    // Directly copy AAC stream
                    if (c.avcodec_parameters_copy(out_stream.*.codecpar, stream.*.codecpar) < 0) return error.CodecCopyFailed;
                    out_stream.*.codecpar.*.codec_tag = 0;
                }
                audio_out_idx = @intCast(out_ctx.*.nb_streams - 1);
            }
        }
    }

    // If requested track not found, fallback to first audio track
    if (audio_in_idx < 0 and audio_idx_requested >= 0) {
        for (0..@intCast(in_ctx.*.nb_streams)) |i| {
            const stream = in_ctx.*.streams[i];
            if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
                audio_in_idx = @intCast(i);
                const out_stream = c.avformat_new_stream(out_ctx, null);
                
                if (stream.*.codecpar.*.codec_id != c.AV_CODEC_ID_AAC) {
                    audio_tr = try transcoder.AudioTranscoder.init(stream, out_stream, start_time);
                } else {
                    if (c.avcodec_parameters_copy(out_stream.*.codecpar, stream.*.codecpar) < 0) return error.CodecCopyFailed;
                    out_stream.*.codecpar.*.codec_tag = 0;
                }
                audio_out_idx = @intCast(out_ctx.*.nb_streams - 1);
                break;
            }
        }
    }

    const avio_buf_size = 32768;
    avio_buf = c.av_malloc(avio_buf_size) orelse return error.OutOfMemory;
    
    out_ctx.*.pb = c.avio_alloc_context(
        @ptrCast(avio_buf.?),
        avio_buf_size,
        1, // write_flag
        @ptrCast(http_ctx), // opaque
        null, // read_packet
        write_packet, // write_packet callback
        null, // seek
    ) orelse return error.AvioContextFailed;

    // movflags: fragmented mp4 configuration
    var dict: ?*c.AVDictionary = null;
    _ = c.av_dict_set(&dict, "movflags", "frag_keyframe+empty_moov+delay_moov+default_base_moof+negative_cts_offsets", 0);
    _ = c.av_dict_set(&dict, "avoid_negative_ts", "make_non_negative", 0);
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

    var last_video_dts: i64 = c.AV_NOPTS_VALUE;

    // Demux and remux loop
    while (c.av_read_frame(in_ctx, packet) >= 0) {
        defer c.av_packet_unref(packet);
        if (http_ctx.has_error) break;

        if (packet.*.stream_index == video_in_idx) {
            packet.*.stream_index = video_out_idx;
            c.av_packet_rescale_ts(packet, in_ctx.*.streams[@intCast(video_in_idx)].*.time_base, out_ctx.*.streams[@intCast(video_out_idx)].*.time_base);
            
            // Fix missing timestamps and enforce strict monotonicity for MP4 muxer
            if (packet.*.dts == c.AV_NOPTS_VALUE) {
                packet.*.dts = if (last_video_dts != c.AV_NOPTS_VALUE) last_video_dts + 1 else 0;
            }
            if (packet.*.pts == c.AV_NOPTS_VALUE) {
                packet.*.pts = packet.*.dts;
            }
            
            // Enforce strictly monotonic DTS
            if (last_video_dts != c.AV_NOPTS_VALUE and packet.*.dts <= last_video_dts) {
                packet.*.dts = last_video_dts + 1;
            }
            
            // PTS must be >= DTS
            if (packet.*.pts < packet.*.dts) {
                packet.*.pts = packet.*.dts;
            }

            last_video_dts = packet.*.dts;

            packet.*.pos = -1;
            if (c.av_interleaved_write_frame(out_ctx, packet) < 0) break;
        } else if (packet.*.stream_index == audio_in_idx) {
            if (audio_tr) |tr| {
                tr.transcodePacket(packet, out_ctx, audio_out_idx) catch {
                    if (http_ctx.has_error) break;
                };
            } else {
                packet.*.stream_index = audio_out_idx;
                c.av_packet_rescale_ts(packet, in_ctx.*.streams[@intCast(audio_in_idx)].*.time_base, out_ctx.*.streams[@intCast(audio_out_idx)].*.time_base);
                packet.*.pos = -1;
                if (c.av_interleaved_write_frame(out_ctx, packet) < 0) break;
            }
        }
    }

    if (!http_ctx.has_error) {
        _ = c.av_write_trailer(out_ctx);
    }

    if (http_ctx.has_error) {
        return error.ConnectionDropped;
    }
}

pub const AudioTrack = struct {
    id: usize,
    label: []const u8,
};

pub const MediaInfo = struct {
    duration: f64,
    codec_str: []const u8,
    audio_tracks: []AudioTrack,
};

/// Retrieves the duration, codec info, and available audio tracks of a media file.
pub fn getMediaInfo(allocator: std.mem.Allocator, file_path: [:0]const u8) !MediaInfo {
    var fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(@ptrCast(&fmt_ctx), file_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(@ptrCast(&fmt_ctx));

    if (c.avformat_find_stream_info(fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    const duration = @as(f64, @floatFromInt(fmt_ctx.?.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
    var codec_str: []const u8 = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\""; // Default

    var audio_tracks: std.ArrayList(AudioTrack) = .empty;
    errdefer {
        for (audio_tracks.items) |track| allocator.free(track.label);
        audio_tracks.deinit(allocator);
    }

    for (0..fmt_ctx.?.nb_streams) |i| {
        const stream = fmt_ctx.?.streams[i];
        if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
            const codec_id = stream.*.codecpar.*.codec_id;
            if (codec_id == c.AV_CODEC_ID_H264) {
                codec_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"";
            } else if (codec_id == c.AV_CODEC_ID_HEVC) {
                codec_str = "video/mp4; codecs=\"hvc1.2.4.L153.B0, mp4a.40.2\"";
            } else if (codec_id == c.AV_CODEC_ID_AV1) {
                codec_str = "video/mp4; codecs=\"av01.0.05M.08, mp4a.40.2\"";
            } else if (codec_id == c.AV_CODEC_ID_VP9) {
                codec_str = "video/mp4; codecs=\"vp09.00.10.08, mp4a.40.2\"";
            }
        } else if (stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            var label: []const u8 = "Unknown";

            const title_entry = c.av_dict_get(stream.*.metadata, "title", null, 0);
            const lang_entry = c.av_dict_get(stream.*.metadata, "language", null, 0);

            if (title_entry != null) {
                label = std.mem.span(title_entry.*.value);
            } else if (lang_entry != null) {
                label = std.mem.span(lang_entry.*.value);
            }

            const label_dup = try allocator.dupe(u8, label);
            try audio_tracks.append(allocator, .{ .id = i, .label = label_dup });
        }
    }

    return MediaInfo{
        .duration = duration,
        .codec_str = codec_str,
        .audio_tracks = try audio_tracks.toOwnedSlice(allocator),
    };
}
