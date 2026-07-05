const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    @cInclude("libavutil/dict.h");
});

const Buffer = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

fn write_packet(ptr: ?*anyopaque, buf: [*c]const u8, buf_size: c_int) callconv(.c) c_int {
    var buffer: *Buffer = @ptrCast(@alignCast(ptr.?));
    buffer.list.appendSlice(buffer.allocator, buf[0..@intCast(buf_size)]) catch return -1;
    return buf_size;
}

const AVIndexEntry = extern struct {
    pos: i64,
    timestamp: i64,
    flags_and_size: i32,
    min_distance: i32,
};

pub fn generateChunk(allocator: std.mem.Allocator, file_path: []const u8, is_audio: bool, track_index: usize, chunk_index: usize, is_init: bool, splits: []const i64) ![]const u8 {
    var in_ctx: ?*c.AVFormatContext = null;
    
    const path_z = try allocator.dupeZ(u8, file_path);
    defer allocator.free(path_z);
    
    if (c.avformat_open_input(&in_ctx, path_z, null, null) != 0) return error.OpenInputFailed;
    defer c.avformat_close_input(&in_ctx);

    if (c.avformat_find_stream_info(in_ctx, null) < 0) return error.FindStreamInfoFailed;

    // Find the requested stream and the master video stream (for timeline)
    var target_stream: ?*c.AVStream = null;
    var master_video_stream: ?*c.AVStream = null;
    var audio_count: usize = 0;
    
    for (0..@intCast(in_ctx.?.*.nb_streams)) |i| {
        const st = in_ctx.?.*.streams[i];
        if (st.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO) {
            if (master_video_stream == null) master_video_stream = st;
            if (!is_audio) target_stream = st;
        } else if (st.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            if (is_audio and audio_count == track_index) target_stream = st;
            audio_count += 1;
        }
    }

    if (target_stream == null or master_video_stream == null) return error.StreamNotFound;

    // Determine start and end timestamps from the splits file
    var chunk_start_ts_v: i64 = 0;
    var chunk_end_ts_v: i64 = c.AV_NOPTS_VALUE;
    
    if (chunk_index > 0 and splits.len > 0) {
        if (chunk_index - 1 < splits.len) {
            chunk_start_ts_v = splits[chunk_index - 1];
        }
        if (chunk_index < splits.len) {
            chunk_end_ts_v = splits[chunk_index];
        }
    }
    

    // Convert video timestamps from splits (AV_TIME_BASE) to target stream timestamps
    const start_ts = c.av_rescale_q(chunk_start_ts_v, c.av_get_time_base_q(), target_stream.?.*.time_base);
    const end_ts = if (chunk_end_ts_v != c.AV_NOPTS_VALUE) c.av_rescale_q(chunk_end_ts_v, c.av_get_time_base_q(), target_stream.?.*.time_base) else c.AV_NOPTS_VALUE;

    std.debug.print("Chunk {d}: splits [{d}, {d}], start_ts={d}, end_ts={d}\n", .{
        chunk_index, chunk_start_ts_v, chunk_end_ts_v, start_ts, end_ts
    });

    // Set up output context in memory
    var out_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_alloc_output_context2(&out_ctx, null, "mp4", null) < 0) return error.AllocOutputFailed;
    defer c.avformat_free_context(out_ctx);

    const out_stream = c.avformat_new_stream(out_ctx, null);
    if (out_stream == null) return error.NewStreamFailed;
    
    if (c.avcodec_parameters_copy(out_stream.*.codecpar, target_stream.?.*.codecpar) < 0) return error.CopyCodecFailed;
    out_stream.*.codecpar.*.codec_tag = 0; // Let muxer choose

    var mem_buffer = Buffer{ .list = .empty, .allocator = allocator };
    defer if (mem_buffer.list.capacity > 0) mem_buffer.list.deinit(allocator);

    const avio_buf_size = 32768;
    const avio_buf = c.av_malloc(avio_buf_size);
    if (avio_buf == null) return error.AvMallocFailed;

    const avio_ctx = c.avio_alloc_context(@ptrCast(avio_buf), avio_buf_size, 1, &mem_buffer, null, write_packet, null);
    if (avio_ctx == null) return error.AvioAllocFailed;
    defer c.av_free(avio_ctx);

    out_ctx.?.*.pb = avio_ctx;

    var opts: ?*c.AVDictionary = null;
    defer c.av_dict_free(&opts);
    
    if (is_init) {
        if (c.av_dict_set(&opts, "movflags", "empty_moov+default_base_moof+frag_keyframe+dash", 0) < 0) return error.DictSetFailed;
    } else {
        if (c.av_dict_set(&opts, "movflags", "empty_moov+default_base_moof+frag_keyframe+dash+frag_discont", 0) < 0) return error.DictSetFailed;
        if (c.av_dict_set(&opts, "avoid_negative_ts", "disabled", 0) < 0) return error.DictSetFailed;
    }
    if (!is_audio) {
        if (c.av_dict_set(&opts, "video_track_timescale", "90000", 0) < 0) return error.DictSetFailed;
    }
    
    // Completely disable avoid_negative_ts so FFmpeg does not shift all our chunks back to 0!
    if (c.av_dict_set(&opts, "avoid_negative_ts", "disabled", 0) < 0) return error.DictSetFailed;

    if (c.avformat_write_header(out_ctx, &opts) < 0) return error.WriteHeaderFailed;

    if (!is_init) {
        // Seek to the start timestamp if it's > 0
        if (start_ts > 0) {
            if (c.av_seek_frame(in_ctx, target_stream.?.*.index, start_ts, c.AVSEEK_FLAG_BACKWARD) < 0) {
                std.debug.print("Seek failed\n", .{});
            }
        }

        var pkt: ?*c.AVPacket = c.av_packet_alloc();
        defer c.av_packet_free(&pkt);

        var last_dts: i64 = c.AV_NOPTS_VALUE;
        
        while (c.av_read_frame(in_ctx, pkt) >= 0) {
            defer c.av_packet_unref(pkt);

            if (pkt.?.*.stream_index == target_stream.?.*.index) {
                if (end_ts != c.AV_NOPTS_VALUE and pkt.?.*.pts != c.AV_NOPTS_VALUE and pkt.?.*.pts >= end_ts) {
                    break; // reached end of chunk
                }

                // If seeking went slightly too far back for audio (which lacks keyframes), we can skip packets before start_ts
                if (is_audio and pkt.?.*.pts != c.AV_NOPTS_VALUE and pkt.?.*.pts < start_ts) {
                    continue;
                }

                // Fix missing DTS caused by seeking in MKV
                if (pkt.?.*.dts == c.AV_NOPTS_VALUE) {
                    if (last_dts == c.AV_NOPTS_VALUE) {
                        pkt.?.*.dts = if (pkt.?.*.pts != c.AV_NOPTS_VALUE) pkt.?.*.pts - 100 else 0;
                    } else {
                        pkt.?.*.dts = last_dts + 1;
                    }
                }
                
                // Ensure strictly monotonic DTS for MP4 muxer
                if (last_dts != c.AV_NOPTS_VALUE and pkt.?.*.dts <= last_dts) {
                    pkt.?.*.dts = last_dts + 1;
                }
                last_dts = pkt.?.*.dts;

                // Hack: If dts is still negative, clip it to 0 to avoid underflowing MP4 baseMediaDecodeTime
                // (Only clip if it's the very first chunk's very first packets)
                if (chunk_index == 1 and pkt.?.*.dts < 0) {
                    pkt.?.*.dts = 0;
                    last_dts = 0; // Prevent subsequent packets from being shifted backwards
                }

                pkt.?.*.stream_index = out_stream.*.index;
                c.av_packet_rescale_ts(pkt, target_stream.?.*.time_base, out_stream.*.time_base);
                pkt.?.*.pos = -1;

                _ = c.av_interleaved_write_frame(out_ctx, pkt);
            }
        }
    }

    _ = c.av_write_trailer(out_ctx);

    // Strip out ftyp and moov for media chunks
    if (!is_init) {
        const bytes = mem_buffer.list.items;
        if (std.mem.indexOf(u8, bytes, "moof")) |moof_idx| {
            if (moof_idx >= 4) {
                const actual_start = moof_idx - 4;
                const result = try allocator.dupe(u8, bytes[actual_start..]);
                return result;
            }
        }
    }

    // Return the whole buffer (for init.mp4 or if stripping failed)
    const result = try allocator.dupe(u8, mem_buffer.list.items);
    return result;
}
