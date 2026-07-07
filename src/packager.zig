const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libswresample/swresample.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libavutil/channel_layout.h");
    @cInclude("libavutil/audio_fifo.h");
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

const ContextPool = struct {
    in_ctx: *c.AVFormatContext,
    mutex: std.Io.Mutex,
};

var cache: ?std.StringHashMap(ContextPool) = null;
var cache_mutex: std.Io.Mutex = std.Io.Mutex.init;

fn getContext(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !*ContextPool {
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);

    if (cache == null) {
        cache = std.StringHashMap(ContextPool).init(std.heap.c_allocator);
    }

    if (cache.?.getPtr(file_path)) |pool| {
        return pool;
    }

    if (cache.?.count() >= 10) {
        var it = cache.?.iterator();
        while (it.next()) |entry| {
            var ctx: ?*c.AVFormatContext = entry.value_ptr.in_ctx;
            c.avformat_close_input(&ctx);
            std.heap.c_allocator.free(entry.key_ptr.*);
        }
        cache.?.clearRetainingCapacity();
    }

    const path_z = try allocator.dupeZ(u8, file_path);
    defer allocator.free(path_z);

    var in_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&in_ctx, path_z, null, null) != 0) return error.OpenInputFailed;
    if (c.avformat_find_stream_info(in_ctx, null) < 0) {
        c.avformat_close_input(&in_ctx);
        return error.FindStreamInfoFailed;
    }

    const pool = ContextPool{
        .in_ctx = in_ctx.?,
        .mutex = std.Io.Mutex.init,
    };
    
    const key_dup = try std.heap.c_allocator.dupe(u8, file_path);
    try cache.?.put(key_dup, pool);
    
    return cache.?.getPtr(file_path).?;
}

pub fn init() void {
    c.av_log_set_level(c.AV_LOG_ERROR);
}

pub fn generateChunk(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, is_audio: bool, track_index: usize, chunk_index: usize, is_init: bool, splits: []const i64) ![]const u8 {
    const pool = try getContext(allocator, io, file_path);
    pool.mutex.lockUncancelable(io);
    defer pool.mutex.unlock(io);
    const in_ctx = pool.in_ctx;

    // Find the requested stream and the master video stream (for timeline)
    var target_stream: ?*c.AVStream = null;
    var master_video_stream: ?*c.AVStream = null;
    var audio_count: usize = 0;
    
    for (0..@intCast(in_ctx.*.nb_streams)) |i| {
        const st = in_ctx.*.streams[i];
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

    // Set up output context in memory
    var out_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_alloc_output_context2(&out_ctx, null, "mp4", null) < 0) return error.AllocOutputFailed;
    defer c.avformat_free_context(out_ctx);

    const out_stream = c.avformat_new_stream(out_ctx, null);
    if (out_stream == null) return error.NewStreamFailed;
    
    if (c.avcodec_parameters_copy(out_stream.*.codecpar, target_stream.?.*.codecpar) < 0) return error.CopyCodecFailed;
    out_stream.*.codecpar.*.codec_tag = 0; // Let muxer choose

    var transcoder: ?AudioTranscoder = null;
    if (is_audio and target_stream.?.*.codecpar.*.codec_id != c.AV_CODEC_ID_AAC) {
        transcoder = AudioTranscoder.init(target_stream.?, out_stream) catch return error.TranscoderInitFailed;
    }
    defer if (transcoder) |*t| t.deinit();

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
        // Seek to the start timestamp
        if (start_ts >= 0) {
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

                // Transcode or write directly
                if (transcoder) |*t| {
                    t.transcodePacket(pkt.?, out_ctx.?, target_stream.?) catch return error.TranscodeFailed;
                } else {
                    // Fix missing DTS caused by seeking in MKV or missing in container
                    if (pkt.?.*.dts == c.AV_NOPTS_VALUE) {
                        if (pkt.?.*.pts != c.AV_NOPTS_VALUE) {
                            pkt.?.*.dts = pkt.?.*.pts;
                        } else {
                            const dur = if (pkt.?.*.duration > 0) pkt.?.*.duration else 40;
                            if (last_dts == c.AV_NOPTS_VALUE) {
                                pkt.?.*.dts = 0;
                            } else {
                                pkt.?.*.dts = last_dts + dur;
                            }
                        }
                    }
                    
                    // Ensure strictly monotonic DTS for MP4 muxer
                    if (last_dts != c.AV_NOPTS_VALUE and pkt.?.*.dts <= last_dts) {
                        pkt.?.*.dts = last_dts + 1;
                    }
                    
                    // MP4 container strictly requires PTS >= DTS
                    if (pkt.?.*.pts != c.AV_NOPTS_VALUE and pkt.?.*.pts < pkt.?.*.dts) {
                        pkt.?.*.pts = pkt.?.*.dts;
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
    }

    if (transcoder) |*t| {
        t.flush(out_ctx.?) catch return error.TranscodeFlushFailed;
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

pub const AudioTranscoder = struct {
    dec_ctx: *c.AVCodecContext,
    enc_ctx: *c.AVCodecContext,
    swr: *c.SwrContext,
    fifo: *c.AVAudioFifo,
    out_stream: *c.AVStream,
    pts: i64,

    pub fn init(in_stream: *c.AVStream, out_stream: *c.AVStream) !AudioTranscoder {
        const dec = c.avcodec_find_decoder(in_stream.*.codecpar.*.codec_id);
        if (dec == null) return error.DecoderNotFound;

        const dec_ctx = c.avcodec_alloc_context3(dec);
        if (dec_ctx == null) return error.AllocDecFailed;
        if (c.avcodec_parameters_to_context(dec_ctx, in_stream.*.codecpar) < 0) return error.DecParamsFailed;
        if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.OpenDecFailed;

        const enc = c.avcodec_find_encoder(c.AV_CODEC_ID_AAC);
        if (enc == null) return error.EncoderNotFound;

        const enc_ctx = c.avcodec_alloc_context3(enc);
        if (enc_ctx == null) return error.AllocEncFailed;

        enc_ctx.*.sample_rate = 48000;
        enc_ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
        enc_ctx.*.bit_rate = 128000;
        c.av_channel_layout_default(&enc_ctx.*.ch_layout, 2);

        // We are generating DASH fragments, so global header is good
        enc_ctx.*.flags |= c.AV_CODEC_FLAG_GLOBAL_HEADER;

        if (c.avcodec_open2(enc_ctx, enc, null) < 0) return error.OpenEncFailed;
        if (c.avcodec_parameters_from_context(out_stream.*.codecpar, enc_ctx) < 0) return error.EncParamsFailed;
        // Fix codec tag
        out_stream.*.codecpar.*.codec_tag = 0;

        var swr: ?*c.SwrContext = null;
        if (c.swr_alloc_set_opts2(&swr, &enc_ctx.*.ch_layout, enc_ctx.*.sample_fmt, enc_ctx.*.sample_rate,
                                  &dec_ctx.*.ch_layout, dec_ctx.*.sample_fmt, dec_ctx.*.sample_rate, 0, null) < 0) return error.SwrAllocFailed;
        if (c.swr_init(swr) < 0) return error.SwrInitFailed;

        const fifo = c.av_audio_fifo_alloc(enc_ctx.*.sample_fmt, enc_ctx.*.ch_layout.nb_channels, 1);
        if (fifo == null) return error.FifoAllocFailed;

        return AudioTranscoder{
            .dec_ctx = dec_ctx,
            .enc_ctx = enc_ctx,
            .swr = swr.?,
            .fifo = fifo.?,
            .out_stream = out_stream,
            .pts = c.AV_NOPTS_VALUE,
        };
    }

    pub fn deinit(self: *AudioTranscoder) void {
        var dec_ptr: ?*c.AVCodecContext = self.dec_ctx;
        c.avcodec_free_context(&dec_ptr);
        var enc_ptr: ?*c.AVCodecContext = self.enc_ctx;
        c.avcodec_free_context(&enc_ptr);
        var swr_ptr: ?*c.SwrContext = self.swr;
        c.swr_free(&swr_ptr);
        c.av_audio_fifo_free(self.fifo);
    }

    pub fn transcodePacket(self: *AudioTranscoder, pkt: *c.AVPacket, out_ctx: *c.AVFormatContext, in_stream: *c.AVStream) !void {
        if (c.avcodec_send_packet(self.dec_ctx, pkt) == 0) {
            var frame: ?*c.AVFrame = c.av_frame_alloc();
            defer c.av_frame_free(&frame);
            
            var resampled_frame: ?*c.AVFrame = c.av_frame_alloc();
            defer c.av_frame_free(&resampled_frame);
            
            while (c.avcodec_receive_frame(self.dec_ctx, frame) == 0) {
                if (self.pts == c.AV_NOPTS_VALUE and frame.?.*.pts != c.AV_NOPTS_VALUE) {
                    const tb_enc = c.AVRational{ .num = 1, .den = self.enc_ctx.*.sample_rate };
                    self.pts = c.av_rescale_q(frame.?.*.pts, in_stream.*.time_base, tb_enc);
                }

                resampled_frame.?.*.nb_samples = frame.?.*.nb_samples;
                resampled_frame.?.*.sample_rate = self.enc_ctx.*.sample_rate;
                resampled_frame.?.*.format = self.enc_ctx.*.sample_fmt;
                _ = c.av_channel_layout_copy(&resampled_frame.?.*.ch_layout, &self.enc_ctx.*.ch_layout);
                
                if (c.av_frame_get_buffer(resampled_frame, 0) < 0) return error.FrameBufFailed;

                _ = c.swr_convert(self.swr, @as([*c]const [*c]u8, @ptrCast(&resampled_frame.?.*.data)), resampled_frame.?.*.nb_samples,
                                  @as([*c]const [*c]const u8, @ptrCast(&frame.?.*.data)), frame.?.*.nb_samples);
                
                _ = c.av_audio_fifo_write(self.fifo, @ptrCast(&resampled_frame.?.*.data), resampled_frame.?.*.nb_samples);
                c.av_frame_unref(resampled_frame);

                try self.encodeAndWrite(out_ctx);
            }
        }
    }

    fn encodeAndWrite(self: *AudioTranscoder, out_ctx: *c.AVFormatContext) !void {
        var enc_pkt: ?*c.AVPacket = c.av_packet_alloc();
        defer c.av_packet_free(&enc_pkt);
        
        while (c.av_audio_fifo_size(self.fifo) >= self.enc_ctx.*.frame_size) {
            var out_frame: ?*c.AVFrame = c.av_frame_alloc();
            defer c.av_frame_free(&out_frame);
            out_frame.?.*.nb_samples = self.enc_ctx.*.frame_size;
            out_frame.?.*.format = self.enc_ctx.*.sample_fmt;
            _ = c.av_channel_layout_copy(&out_frame.?.*.ch_layout, &self.enc_ctx.*.ch_layout);
            out_frame.?.*.sample_rate = self.enc_ctx.*.sample_rate;
            if (c.av_frame_get_buffer(out_frame, 0) < 0) return error.OutFrameBufFailed;

            _ = c.av_audio_fifo_read(self.fifo, @ptrCast(&out_frame.?.*.data), self.enc_ctx.*.frame_size);
            
            out_frame.?.*.pts = self.pts;
            self.pts += self.enc_ctx.*.frame_size;

            if (c.avcodec_send_frame(self.enc_ctx, out_frame) == 0) {
                while (c.avcodec_receive_packet(self.enc_ctx, enc_pkt) == 0) {
                    c.av_packet_rescale_ts(enc_pkt, self.enc_ctx.*.time_base, self.out_stream.*.time_base);
                    enc_pkt.?.*.stream_index = self.out_stream.*.index;
                    _ = c.av_interleaved_write_frame(out_ctx, enc_pkt);
                    c.av_packet_unref(enc_pkt);
                }
            }
        }
    }

    pub fn flush(self: *AudioTranscoder, out_ctx: *c.AVFormatContext) !void {
        var enc_pkt: ?*c.AVPacket = c.av_packet_alloc();
        defer c.av_packet_free(&enc_pkt);
        
        while (c.av_audio_fifo_size(self.fifo) > 0) {
            var out_frame: ?*c.AVFrame = c.av_frame_alloc();
            defer c.av_frame_free(&out_frame);
            const rem = c.av_audio_fifo_size(self.fifo);
            out_frame.?.*.nb_samples = rem;
            out_frame.?.*.format = self.enc_ctx.*.sample_fmt;
            _ = c.av_channel_layout_copy(&out_frame.?.*.ch_layout, &self.enc_ctx.*.ch_layout);
            out_frame.?.*.sample_rate = self.enc_ctx.*.sample_rate;
            if (c.av_frame_get_buffer(out_frame, 0) < 0) return error.OutFrameBufFailed;

            _ = c.av_audio_fifo_read(self.fifo, @ptrCast(&out_frame.?.*.data), rem);
            
            out_frame.?.*.pts = self.pts;
            self.pts += rem;

            if (c.avcodec_send_frame(self.enc_ctx, out_frame) == 0) {
                while (c.avcodec_receive_packet(self.enc_ctx, enc_pkt) == 0) {
                    c.av_packet_rescale_ts(enc_pkt, self.enc_ctx.*.time_base, self.out_stream.*.time_base);
                    enc_pkt.?.*.stream_index = self.out_stream.*.index;
                    _ = c.av_interleaved_write_frame(out_ctx, enc_pkt);
                    c.av_packet_unref(enc_pkt);
                }
            }
        }

        if (c.avcodec_send_frame(self.enc_ctx, null) == 0) {
            while (c.avcodec_receive_packet(self.enc_ctx, enc_pkt) == 0) {
                c.av_packet_rescale_ts(enc_pkt, self.enc_ctx.*.time_base, self.out_stream.*.time_base);
                enc_pkt.?.*.stream_index = self.out_stream.*.index;
                _ = c.av_interleaved_write_frame(out_ctx, enc_pkt);
                c.av_packet_unref(enc_pkt);
            }
        }
    }
};
