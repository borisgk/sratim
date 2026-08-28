const std = @import("std");
pub const c = @import("../core/c.zig").c;
pub const dsp = @import("native/audio/dsp.zig");
pub const mdct = @import("native/audio/mdct.zig");
pub const ac3_dec = @import("native/audio/ac3_dec.zig");
pub const aac_enc = @import("native/audio/aac_enc.zig");

/// AudioTranscoder handles on-the-fly audio transcoding using FFmpeg's C API.
/// It decodes incoming audio packets (e.g., AC3), resamples them (e.g., to 48kHz stereo),
/// buffers them in a FIFO queue, and encodes them to AAC for web compatibility.
pub const AudioTranscoder = struct {
    decode_ctx: *c.AVCodecContext,
    encode_ctx: *c.AVCodecContext,
    swr_ctx: ?*c.SwrContext,
    fifo: *c.AVAudioFifo,
    frame_in: *c.AVFrame,
    frame_out: *c.AVFrame,
    in_tb: c.AVRational,
    pts_counter: i64 = c.AV_NOPTS_VALUE,

    /// Initializes a new AudioTranscoder instance.
    /// Allocates decoder, encoder, resampler, and internal frames/buffers.
    pub fn init(in_stream: [*c]c.AVStream, out_stream: [*c]c.AVStream, start_time: f64) !*AudioTranscoder {
        const allocator = std.heap.c_allocator;
        var self = try allocator.create(AudioTranscoder);
        errdefer allocator.destroy(self);

        // Decoder
        const dec = c.avcodec_find_decoder(in_stream.*.codecpar.*.codec_id);
        if (dec == null) return error.DecoderNotFound;
        self.decode_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(@ptrCast(&self.decode_ctx));
        if (c.avcodec_parameters_to_context(self.decode_ctx, in_stream.*.codecpar) < 0) return error.CodecParamsError;
        if (c.avcodec_open2(self.decode_ctx, dec, null) < 0) return error.DecoderOpenError;

        // Encoder
        const enc = c.avcodec_find_encoder(c.AV_CODEC_ID_AAC);
        if (enc == null) return error.EncoderNotFound;
        self.encode_ctx = c.avcodec_alloc_context3(enc) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(@ptrCast(&self.encode_ctx));

        if (@hasDecl(c, "av_channel_layout_default")) {
            c.av_channel_layout_default(&self.encode_ctx.*.ch_layout, 2);
        } else {
            self.encode_ctx.*.channel_layout = c.AV_CH_LAYOUT_STEREO;
            self.encode_ctx.*.channels = 2;
        }
        self.encode_ctx.*.sample_rate = 48000;
        if (@hasDecl(c, "avcodec_get_supported_config") and @hasDecl(c, "AV_CODEC_CONFIG_SAMPLE_FORMAT")) {
            var sample_fmts: [*c]const c.AVSampleFormat = null;
            if (c.avcodec_get_supported_config(self.encode_ctx, enc, c.AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, @ptrCast(&sample_fmts), null) >= 0 and sample_fmts != null) {
                self.encode_ctx.*.sample_fmt = sample_fmts[0];
            } else {
                self.encode_ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
            }
        } else if (@hasField(c.AVCodec, "sample_fmts")) {
            if (enc.*.sample_fmts != null) {
                self.encode_ctx.*.sample_fmt = enc.*.sample_fmts[0];
            } else {
                self.encode_ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
            }
        } else {
            self.encode_ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
        }
        self.encode_ctx.*.bit_rate = 192000;
        self.encode_ctx.*.time_base = c.AVRational{ .num = 1, .den = self.encode_ctx.*.sample_rate };

        if (c.avcodec_open2(self.encode_ctx, enc, null) < 0) return error.EncoderOpenError;
        if (c.avcodec_parameters_from_context(out_stream.*.codecpar, self.encode_ctx) < 0) return error.CodecParamsError;

        // SwrContext
        self.swr_ctx = null;
        if (@hasDecl(c, "swr_alloc_set_opts2")) {
            if (c.swr_alloc_set_opts2(
                @ptrCast(&self.swr_ctx),
                &self.encode_ctx.*.ch_layout,
                self.encode_ctx.*.sample_fmt,
                self.encode_ctx.*.sample_rate,
                &self.decode_ctx.*.ch_layout,
                self.decode_ctx.*.sample_fmt,
                self.decode_ctx.*.sample_rate,
                0,
                null,
            ) < 0) return error.SwrInitError;
        } else {
            const encode_cl = if (self.encode_ctx.*.channel_layout == 0) c.av_get_default_channel_layout(self.encode_ctx.*.channels) else @as(i64, @intCast(self.encode_ctx.*.channel_layout));
            const decode_cl = if (self.decode_ctx.*.channel_layout == 0) c.av_get_default_channel_layout(self.decode_ctx.*.channels) else @as(i64, @intCast(self.decode_ctx.*.channel_layout));
            self.swr_ctx = c.swr_alloc_set_opts(
                null,
                encode_cl,
                self.encode_ctx.*.sample_fmt,
                self.encode_ctx.*.sample_rate,
                decode_cl,
                self.decode_ctx.*.sample_fmt,
                self.decode_ctx.*.sample_rate,
                0,
                null,
            );
            if (self.swr_ctx == null) return error.SwrInitError;
        }
        errdefer c.swr_free(@ptrCast(&self.swr_ctx));
        if (c.swr_init(self.swr_ctx.?) < 0) return error.SwrInitError;

        // Fifo
        const enc_channels = if (@hasDecl(c, "av_channel_layout_default")) self.encode_ctx.*.ch_layout.nb_channels else self.encode_ctx.*.channels;
        self.fifo = c.av_audio_fifo_alloc(self.encode_ctx.*.sample_fmt, enc_channels, 1) orelse return error.OutOfMemory;
        errdefer c.av_audio_fifo_free(self.fifo);
        
        self.frame_in = c.av_frame_alloc() orelse return error.OutOfMemory;
        errdefer c.av_frame_free(@ptrCast(&self.frame_in));

        self.frame_out = c.av_frame_alloc() orelse return error.OutOfMemory;
        errdefer c.av_frame_free(@ptrCast(&self.frame_out));

        self.frame_out.*.nb_samples = self.encode_ctx.*.frame_size;
        if (@hasDecl(c, "av_channel_layout_copy")) {
            _ = c.av_channel_layout_copy(&self.frame_out.*.ch_layout, &self.encode_ctx.*.ch_layout);
        } else {
            self.frame_out.*.channel_layout = self.encode_ctx.*.channel_layout;
            self.frame_out.*.channels = self.encode_ctx.*.channels;
        }
        self.frame_out.*.format = self.encode_ctx.*.sample_fmt;
        self.frame_out.*.sample_rate = self.encode_ctx.*.sample_rate;
        if (c.av_frame_get_buffer(self.frame_out, 0) < 0) return error.OutOfMemory;

        _ = start_time;
        self.in_tb = in_stream.*.time_base;
        self.pts_counter = c.AV_NOPTS_VALUE;
        return self;
    }

    /// Cleans up all FFmpeg contexts, frames, and frees the struct memory.
    pub fn deinit(self: *AudioTranscoder) void {
        // Flush the encoder to prevent "frames left in the queue" warning
        _ = c.avcodec_send_frame(self.encode_ctx, null);
        var out_pkt = c.av_packet_alloc();
        if (out_pkt != null) {
            while (c.avcodec_receive_packet(self.encode_ctx, out_pkt) >= 0) {
                c.av_packet_unref(out_pkt);
            }
            c.av_packet_free(@ptrCast(&out_pkt));
        }

        c.av_frame_free(@ptrCast(&self.frame_in));
        c.av_frame_free(@ptrCast(&self.frame_out));
        c.av_audio_fifo_free(self.fifo);
        c.swr_free(@ptrCast(&self.swr_ctx));
        c.avcodec_free_context(@ptrCast(&self.encode_ctx));
        c.avcodec_free_context(@ptrCast(&self.decode_ctx));
        std.heap.c_allocator.destroy(self);
    }

    /// Transcodes a single encoded input packet and writes it into the output context.
    /// Manages the FFmpeg send/receive decode loop, resampling, FIFO buffering, and encoding loop.
    pub fn transcodePacket(self: *AudioTranscoder, in_packet: *c.AVPacket, out_fmt_ctx: *c.AVFormatContext, stream_idx: c_int) !void {
        if (self.pts_counter == c.AV_NOPTS_VALUE) {
            if (in_packet.*.pts != c.AV_NOPTS_VALUE) {
                self.pts_counter = c.av_rescale_q(in_packet.*.pts, self.in_tb, self.encode_ctx.*.time_base);
            } else if (in_packet.*.dts != c.AV_NOPTS_VALUE) {
                self.pts_counter = c.av_rescale_q(in_packet.*.dts, self.in_tb, self.encode_ctx.*.time_base);
            } else {
                self.pts_counter = 0;
            }
        }

        if (c.avcodec_send_packet(self.decode_ctx, in_packet) < 0) return;

        while (c.avcodec_receive_frame(self.decode_ctx, self.frame_in) >= 0) {
            var conv_buf: [2][4096]f32 = undefined;
            var out_ptrs = [_][*c]u8{ @ptrCast(&conv_buf[0]), @ptrCast(&conv_buf[1]) };

            const in_data = @as([*c][*c]const u8, @ptrCast(&self.frame_in.*.data));
            const real_out_samples = c.swr_convert(self.swr_ctx.?, &out_ptrs, 4096, in_data, self.frame_in.*.nb_samples);
            if (real_out_samples > 0) {
                _ = c.av_audio_fifo_write(self.fifo, @ptrCast(&out_ptrs), real_out_samples);
            }
        }

        while (c.av_audio_fifo_size(self.fifo) >= self.encode_ctx.*.frame_size) {
            _ = c.av_audio_fifo_read(self.fifo, @ptrCast(&self.frame_out.*.data), self.encode_ctx.*.frame_size);
            self.frame_out.*.pts = self.pts_counter;
            self.pts_counter += self.frame_out.*.nb_samples;

            if (c.avcodec_send_frame(self.encode_ctx, self.frame_out) < 0) return;

            var out_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
            defer c.av_packet_free(@ptrCast(&out_pkt));

            while (c.avcodec_receive_packet(self.encode_ctx, out_pkt) >= 0) {
                out_pkt.*.stream_index = stream_idx;
                c.av_packet_rescale_ts(out_pkt, self.encode_ctx.*.time_base, out_fmt_ctx.*.streams[@intCast(stream_idx)].*.time_base);
                if (c.av_interleaved_write_frame(out_fmt_ctx, out_pkt) < 0) return error.WriteError;
            }
        }
    }
};

pub const EncodedAacFrame = struct {
    data: []u8,
    sample_count: u32 = 1024,
};

/// Standalone audio transcoder that converts arbitrary compressed audio packets (AC3, DTS, EAC3, multichannel AAC)
/// into standardized 48kHz Stereo AAC frames for native fMP4 container muxing.
pub const StreamAudioTranscoder = struct {
    decode_ctx: *c.AVCodecContext,
    encode_ctx: *c.AVCodecContext,
    swr_ctx: ?*c.SwrContext = null,
    fifo: *c.AVAudioFifo,
    frame_in: *c.AVFrame,
    frame_out: *c.AVFrame,
    in_pkt: *c.AVPacket,
    out_pkt: *c.AVPacket,
    pts_counter: i64 = 0,
    swr_in_channels: i32 = 0,
    swr_in_rate: i32 = 0,
    swr_in_fmt: c.AVSampleFormat = c.AV_SAMPLE_FMT_NONE,
    native_aac_enc: aac_enc.AacEncoder = aac_enc.AacEncoder.init(48000, 192000),
    native_ac3_dec: ?ac3_dec.Ac3Decoder = null,
    use_native_encoder: bool = true,

    pub fn mapCodecId(codec_name: []const u8) ?c.AVCodecID {
        if (std.mem.eql(u8, codec_name, "A_AC3") or std.mem.eql(u8, codec_name, "ac-3") or std.mem.eql(u8, codec_name, "sac3")) {
            return c.AV_CODEC_ID_AC3;
        } else if (std.mem.eql(u8, codec_name, "A_EAC3") or std.mem.eql(u8, codec_name, "ec-3")) {
            return c.AV_CODEC_ID_EAC3;
        } else if (std.mem.eql(u8, codec_name, "A_DTS") or std.mem.eql(u8, codec_name, "dts ") or std.mem.eql(u8, codec_name, "dtsc") or std.mem.eql(u8, codec_name, "dtsh") or std.mem.eql(u8, codec_name, "dtsl")) {
            return c.AV_CODEC_ID_DTS;
        } else if (std.mem.eql(u8, codec_name, "A_AAC") or std.mem.eql(u8, codec_name, "mp4a")) {
            return c.AV_CODEC_ID_AAC;
        } else if (std.mem.eql(u8, codec_name, "A_FLAC") or std.mem.eql(u8, codec_name, "flac")) {
            return c.AV_CODEC_ID_FLAC;
        } else if (std.mem.eql(u8, codec_name, "A_TRUEHD")) {
            return c.AV_CODEC_ID_TRUEHD;
        } else if (std.mem.eql(u8, codec_name, "A_VORBIS")) {
            return c.AV_CODEC_ID_VORBIS;
        } else if (std.mem.eql(u8, codec_name, "A_OPUS") or std.mem.eql(u8, codec_name, "Opus")) {
            return c.AV_CODEC_ID_OPUS;
        } else if (std.mem.eql(u8, codec_name, "A_MPEG/L3")) {
            return c.AV_CODEC_ID_MP3;
        } else if (std.mem.eql(u8, codec_name, "A_MPEG/L2")) {
            return c.AV_CODEC_ID_MP2;
        }
        return null;
    }

    pub fn initFromCodec(
        codec_name: []const u8,
        codec_private: ?[]const u8,
        channels: u16,
        sample_rate: u32,
        use_native_encoder: bool,
    ) !*StreamAudioTranscoder {
        const av_codec_id = mapCodecId(codec_name) orelse return error.UnsupportedAudioCodec;
        const dec = c.avcodec_find_decoder(av_codec_id) orelse return error.DecoderNotFound;

        const allocator = std.heap.c_allocator;
        var self = try allocator.create(StreamAudioTranscoder);
        errdefer allocator.destroy(self);

        self.native_aac_enc = aac_enc.AacEncoder.init(48000, 192000);
        self.use_native_encoder = use_native_encoder;
        self.swr_ctx = null;
        self.pts_counter = 0;
        self.swr_in_channels = 0;
        self.swr_in_rate = 0;
        self.swr_in_fmt = c.AV_SAMPLE_FMT_NONE;
        self.native_ac3_dec = if (use_native_encoder and av_codec_id == c.AV_CODEC_ID_AC3)
            ac3_dec.Ac3Decoder.init()
        else
            null;

        // Decoder Context
        self.decode_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(@ptrCast(&self.decode_ctx));

        self.decode_ctx.*.sample_rate = @intCast(if (sample_rate > 0) sample_rate else 48000);
        const in_channels_i32: i32 = @intCast(if (channels > 0) channels else 2);
        if (@hasDecl(c, "av_channel_layout_default")) {
            c.av_channel_layout_default(&self.decode_ctx.*.ch_layout, in_channels_i32);
        } else {
            self.decode_ctx.*.channels = in_channels_i32;
            self.decode_ctx.*.channel_layout = @as(u64, @bitCast(c.av_get_default_channel_layout(in_channels_i32)));
        }

        if (codec_private) |cp| {
            if (cp.len > 0) {
                const extradata = c.av_malloc(cp.len + c.AV_INPUT_BUFFER_PADDING_SIZE);
                if (extradata != null) {
                    const extra_slice: [*c]u8 = @ptrCast(extradata);
                    @memcpy(extra_slice[0..cp.len], cp);
                    @memset(extra_slice[cp.len .. cp.len + c.AV_INPUT_BUFFER_PADDING_SIZE], 0);
                    self.decode_ctx.*.extradata = extra_slice;
                    self.decode_ctx.*.extradata_size = @intCast(cp.len);
                }
            }
        }

        if (c.avcodec_open2(self.decode_ctx, dec, null) < 0) return error.DecoderOpenError;

        // Encoder Context (Standard Web-compatible 48kHz Stereo AAC)
        const enc = c.avcodec_find_encoder(c.AV_CODEC_ID_AAC) orelse return error.EncoderNotFound;
        self.encode_ctx = c.avcodec_alloc_context3(enc) orelse return error.OutOfMemory;
        errdefer c.avcodec_free_context(@ptrCast(&self.encode_ctx));

        if (@hasDecl(c, "av_channel_layout_default")) {
            c.av_channel_layout_default(&self.encode_ctx.*.ch_layout, 2);
        } else {
            self.encode_ctx.*.channels = 2;
            self.encode_ctx.*.channel_layout = c.AV_CH_LAYOUT_STEREO;
        }
        self.encode_ctx.*.sample_rate = 48000;
        self.encode_ctx.*.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
        self.encode_ctx.*.bit_rate = 192000;
        self.encode_ctx.*.time_base = c.AVRational{ .num = 1, .den = 48000 };

        if (c.avcodec_open2(self.encode_ctx, enc, null) < 0) return error.EncoderOpenError;

        // FIFO Buffer
        self.fifo = c.av_audio_fifo_alloc(self.encode_ctx.*.sample_fmt, 2, 1024) orelse return error.OutOfMemory;
        errdefer c.av_audio_fifo_free(self.fifo);

        self.frame_in = c.av_frame_alloc() orelse return error.OutOfMemory;
        errdefer c.av_frame_free(@ptrCast(&self.frame_in));

        self.frame_out = c.av_frame_alloc() orelse return error.OutOfMemory;
        errdefer c.av_frame_free(@ptrCast(&self.frame_out));

        self.frame_out.*.nb_samples = self.encode_ctx.*.frame_size;
        if (@hasDecl(c, "av_channel_layout_copy")) {
            _ = c.av_channel_layout_copy(&self.frame_out.*.ch_layout, &self.encode_ctx.*.ch_layout);
        } else {
            self.frame_out.*.channel_layout = self.encode_ctx.*.channel_layout;
            self.frame_out.*.channels = self.encode_ctx.*.channels;
        }
        self.frame_out.*.format = self.encode_ctx.*.sample_fmt;
        self.frame_out.*.sample_rate = self.encode_ctx.*.sample_rate;
        if (c.av_frame_get_buffer(self.frame_out, 0) < 0) return error.OutOfMemory;

        self.in_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
        errdefer c.av_packet_free(@ptrCast(&self.in_pkt));

        self.out_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
        errdefer c.av_packet_free(@ptrCast(&self.out_pkt));

        return self;
    }

    fn initOrUpdateSwr(self: *StreamAudioTranscoder) !void {
        const in_rate = self.decode_ctx.*.sample_rate;
        const in_fmt = self.decode_ctx.*.sample_fmt;
        const in_channels: i32 = if (@hasDecl(c, "av_channel_layout_default")) self.decode_ctx.*.ch_layout.nb_channels else self.decode_ctx.*.channels;

        if (self.swr_ctx != null and self.swr_in_rate == in_rate and self.swr_in_fmt == in_fmt and self.swr_in_channels == in_channels) {
            return;
        }

        if (self.swr_ctx) |old_swr| {
            var temp_swr: ?*c.SwrContext = old_swr;
            c.swr_free(@ptrCast(&temp_swr));
            self.swr_ctx = null;
        }

        self.swr_in_rate = in_rate;
        self.swr_in_fmt = in_fmt;
        self.swr_in_channels = in_channels;

        if (@hasDecl(c, "swr_alloc_set_opts2")) {
            if (c.swr_alloc_set_opts2(
                @ptrCast(&self.swr_ctx),
                &self.encode_ctx.*.ch_layout,
                self.encode_ctx.*.sample_fmt,
                self.encode_ctx.*.sample_rate,
                &self.decode_ctx.*.ch_layout,
                self.decode_ctx.*.sample_fmt,
                self.decode_ctx.*.sample_rate,
                0,
                null,
            ) < 0) return error.SwrInitError;
        } else {
            const encode_cl = @as(i64, @bitCast(@as(u64, c.AV_CH_LAYOUT_STEREO)));
            const decode_cl = if (self.decode_ctx.*.channel_layout == 0) c.av_get_default_channel_layout(self.decode_ctx.*.channels) else @as(i64, @bitCast(self.decode_ctx.*.channel_layout));
            self.swr_ctx = c.swr_alloc_set_opts(
                null,
                encode_cl,
                self.encode_ctx.*.sample_fmt,
                self.encode_ctx.*.sample_rate,
                decode_cl,
                self.decode_ctx.*.sample_fmt,
                self.decode_ctx.*.sample_rate,
                0,
                null,
            );
            if (self.swr_ctx == null) return error.SwrInitError;
        }

        if (c.swr_init(self.swr_ctx.?) < 0) return error.SwrInitError;
    }

    /// Feeds a raw audio packet from demuxer into the transcoder and collects any ready AAC frames.
    pub fn transcodePacket(
        self: *StreamAudioTranscoder,
        allocator: std.mem.Allocator,
        raw_payload: []const u8,
        out_frames: *std.ArrayList(EncodedAacFrame),
    ) !void {
        if (self.native_ac3_dec) |*ac3| {
            var offset: usize = 0;
            var decoded_any = false;
            while (offset + 7 <= raw_payload.len) {
                if (raw_payload[offset] != 0x0B or raw_payload[offset + 1] != 0x77) {
                    offset += 1;
                    continue;
                }
                const fscod: usize = (raw_payload[offset + 4] >> 6) & 3;
                const frmsizecod: usize = raw_payload[offset + 4] & 0x3F;
                if (fscod >= 3 or frmsizecod >= 38) {
                    offset += 2;
                    continue;
                }
                const frame_size = @as(usize, ac3_dec.FRAME_SIZE_TABLE[frmsizecod][fscod]) * 2;
                if (offset + frame_size > raw_payload.len) break;

                const frame_bytes = raw_payload[offset .. offset + frame_size];
                var stereo_interleaved: [1536 * 2]f32 = undefined;
                if (ac3.decodeFrame(frame_bytes, &stereo_interleaved)) |n_samples| {
                    if (n_samples > 0) {
                        var planar_l: [1536]f32 = undefined;
                        var planar_r: [1536]f32 = undefined;
                        for (0..n_samples) |i| {
                            planar_l[i] = stereo_interleaved[i * 2 + 0];
                            planar_r[i] = stereo_interleaved[i * 2 + 1];
                        }
                        var out_ptrs = [_][*c]u8{ @ptrCast(&planar_l), @ptrCast(&planar_r) };
                        _ = c.av_audio_fifo_write(self.fifo, @ptrCast(&out_ptrs), @intCast(n_samples));
                        decoded_any = true;
                    }
                } else |_| {}
                offset += frame_size;
            }
            if (decoded_any) {
                try self.drainFifo(allocator, out_frames);
                return;
            }
        }

        c.av_packet_unref(self.in_pkt);
        self.in_pkt.*.data = @constCast(raw_payload.ptr);
        self.in_pkt.*.size = @intCast(raw_payload.len);

        if (c.avcodec_send_packet(self.decode_ctx, self.in_pkt) < 0) return;

        while (c.avcodec_receive_frame(self.decode_ctx, self.frame_in) >= 0) {
            try self.initOrUpdateSwr();

            var conv_buf: [2][4096]f32 = undefined;
            var out_ptrs = [_][*c]u8{ @ptrCast(&conv_buf[0]), @ptrCast(&conv_buf[1]) };

            const in_data = @as([*c][*c]const u8, @ptrCast(&self.frame_in.*.data));
            const real_out_samples = c.swr_convert(self.swr_ctx.?, &out_ptrs, 4096, in_data, self.frame_in.*.nb_samples);
            if (real_out_samples > 0) {
                _ = c.av_audio_fifo_write(self.fifo, @ptrCast(&out_ptrs), real_out_samples);
            }
        }

        try self.drainFifo(allocator, out_frames);
    }

    fn drainFifo(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
        if (self.use_native_encoder) {
            while (c.av_audio_fifo_size(self.fifo) >= 1024) {
                var planar_buf: [2][1024]f32 = undefined;
                var out_ptrs = [_][*c]u8{ @ptrCast(&planar_buf[0]), @ptrCast(&planar_buf[1]) };
                _ = c.av_audio_fifo_read(self.fifo, @ptrCast(&out_ptrs), 1024);

                var aac_frame_buf: [2048]u8 = undefined;
                const aac_len = try self.native_aac_enc.encodeFrame(&planar_buf[0], &planar_buf[1], &aac_frame_buf);

                const frame_buf = try allocator.alloc(u8, aac_len);
                errdefer allocator.free(frame_buf);
                @memcpy(frame_buf, aac_frame_buf[0..aac_len]);

                try out_frames.append(allocator, EncodedAacFrame{
                    .data = frame_buf,
                    .sample_count = 1024,
                });
            }
            return;
        }

        while (c.av_audio_fifo_size(self.fifo) >= self.encode_ctx.*.frame_size) {
            _ = c.av_audio_fifo_read(self.fifo, @ptrCast(&self.frame_out.*.data), self.encode_ctx.*.frame_size);
            self.frame_out.*.pts = self.pts_counter;
            self.pts_counter += self.frame_out.*.nb_samples;

            if (c.avcodec_send_frame(self.encode_ctx, self.frame_out) < 0) return;

            while (c.avcodec_receive_packet(self.encode_ctx, self.out_pkt) >= 0) {
                defer c.av_packet_unref(self.out_pkt);
                const aac_len: usize = @intCast(self.out_pkt.*.size);
                const frame_buf = try allocator.alloc(u8, aac_len);
                errdefer allocator.free(frame_buf);
                @memcpy(frame_buf, self.out_pkt.*.data[0..aac_len]);

                try out_frames.append(allocator, EncodedAacFrame{
                    .data = frame_buf,
                    .sample_count = 1024,
                });
            }
        }
    }

    /// Flushes any remaining samples in the FIFO and encoder queue.
    pub fn flush(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
        const remaining_samples = c.av_audio_fifo_size(self.fifo);
        if (remaining_samples > 0) {
            if (self.use_native_encoder) {
                var planar_buf: [2][1024]f32 = undefined;
                @memset(&planar_buf[0], 0.0);
                @memset(&planar_buf[1], 0.0);
                var out_ptrs = [_][*c]u8{ @ptrCast(&planar_buf[0]), @ptrCast(&planar_buf[1]) };
                _ = c.av_audio_fifo_read(self.fifo, @ptrCast(&out_ptrs), remaining_samples);

                var aac_frame_buf: [2048]u8 = undefined;
                const aac_len = try self.native_aac_enc.encodeFrame(&planar_buf[0], &planar_buf[1], &aac_frame_buf);

                const frame_buf = try allocator.alloc(u8, aac_len);
                errdefer allocator.free(frame_buf);
                @memcpy(frame_buf, aac_frame_buf[0..aac_len]);

                try out_frames.append(allocator, EncodedAacFrame{
                    .data = frame_buf,
                    .sample_count = 1024,
                });
                return;
            }

            @memset(self.frame_out.*.data[0][0 .. @intCast(self.encode_ctx.*.frame_size * 4)], 0);
            @memset(self.frame_out.*.data[1][0 .. @intCast(self.encode_ctx.*.frame_size * 4)], 0);
            _ = c.av_audio_fifo_read(self.fifo, @ptrCast(&self.frame_out.*.data), remaining_samples);
            self.frame_out.*.pts = self.pts_counter;
            self.pts_counter += self.frame_out.*.nb_samples;

            _ = c.avcodec_send_frame(self.encode_ctx, self.frame_out);
            while (c.avcodec_receive_packet(self.encode_ctx, self.out_pkt) >= 0) {
                defer c.av_packet_unref(self.out_pkt);
                const aac_len: usize = @intCast(self.out_pkt.*.size);
                const frame_buf = try allocator.alloc(u8, aac_len);
                errdefer allocator.free(frame_buf);
                @memcpy(frame_buf, self.out_pkt.*.data[0..aac_len]);

                try out_frames.append(allocator, EncodedAacFrame{
                    .data = frame_buf,
                    .sample_count = 1024,
                });
            }
        }

        if (!self.use_native_encoder) {
            _ = c.avcodec_send_frame(self.encode_ctx, null);
            while (c.avcodec_receive_packet(self.encode_ctx, self.out_pkt) >= 0) {
                defer c.av_packet_unref(self.out_pkt);
                const aac_len: usize = @intCast(self.out_pkt.*.size);
                const frame_buf = try allocator.alloc(u8, aac_len);
                errdefer allocator.free(frame_buf);
                @memcpy(frame_buf, self.out_pkt.*.data[0..aac_len]);

                try out_frames.append(allocator, EncodedAacFrame{
                    .data = frame_buf,
                    .sample_count = 1024,
                });
            }
        }
    }

    pub fn deinit(self: *StreamAudioTranscoder) void {
        c.av_packet_free(@ptrCast(&self.in_pkt));
        c.av_packet_free(@ptrCast(&self.out_pkt));
        c.av_frame_free(@ptrCast(&self.frame_in));
        c.av_frame_free(@ptrCast(&self.frame_out));
        c.av_audio_fifo_free(self.fifo);
        if (self.swr_ctx) |swr| {
            var temp_swr: ?*c.SwrContext = swr;
            c.swr_free(@ptrCast(&temp_swr));
        }
        c.avcodec_free_context(@ptrCast(&self.encode_ctx));
        c.avcodec_free_context(@ptrCast(&self.decode_ctx));
        std.heap.c_allocator.destroy(self);
    }
};

test "AudioTranscoder preserves initial PTS" {
    const testing = std.testing;

    const path = "tests/test_sync.mkv";
    const io = testing.io;
    _ = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;

    const c_path = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(c_path);

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(@ptrCast(&in_fmt_ctx), c_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(@ptrCast(&in_fmt_ctx));

    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    var audio_stream_idx: usize = 0;
    var audio_stream: [*c]c.AVStream = undefined;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            audio_stream_idx = i;
            audio_stream = in_fmt_ctx.?.streams[i];
            break;
        }
    }

    const out_fmt = c.av_guess_format("mp4", null, null);
    var out_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_alloc_output_context2(@ptrCast(&out_fmt_ctx), out_fmt, null, null) < 0) return error.AllocFailed;
    defer c.avformat_free_context(out_fmt_ctx);

    const out_stream = c.avformat_new_stream(out_fmt_ctx.?, null);

    var transcoder = try AudioTranscoder.init(audio_stream, out_stream, 0.0);
    defer transcoder.deinit();

    try testing.expect(transcoder.pts_counter == c.AV_NOPTS_VALUE);

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    var found_audio = false;
    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        if (pkt.*.stream_index == audio_stream_idx) {
            pkt.*.pts = 5000;
            
            transcoder.transcodePacket(pkt, out_fmt_ctx.?, @intCast(out_stream.*.index)) catch |err| {
                if (err != error.WriteError) return err;
            };
            found_audio = true;
            break;
        }
        c.av_packet_unref(pkt);
    }
    
    try testing.expect(found_audio);
    try testing.expect(transcoder.pts_counter > 0);
}

test "StreamAudioTranscoder decodes and encodes AAC frames" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const path = "tests/test_sync.mkv";
    const io = testing.io;
    _ = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;

    const c_path = try std.heap.c_allocator.dupeZ(u8, path);
    defer std.heap.c_allocator.free(c_path);

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(@ptrCast(&in_fmt_ctx), c_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(@ptrCast(&in_fmt_ctx));

    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    var audio_stream_idx: usize = 0;
    var audio_stream: [*c]c.AVStream = undefined;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            audio_stream_idx = i;
            audio_stream = in_fmt_ctx.?.streams[i];
            break;
        }
    }

    const extradata_slice: ?[]const u8 = if (audio_stream.*.codecpar.*.extradata_size > 0)
        audio_stream.*.codecpar.*.extradata[0..@intCast(audio_stream.*.codecpar.*.extradata_size)]
    else
        null;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AAC", extradata_slice, 2, 48000, true);
    defer transcoder.deinit();

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == audio_stream_idx) {
            const raw_data: []const u8 = pkt.*.data[0..@intCast(pkt.*.size)];
            try transcoder.transcodePacket(allocator, raw_data, &frames);
            if (frames.items.len >= 2) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len > 0);
    try testing.expect(frames.items[0].data.len > 0);

    const dec = c.avcodec_find_decoder(c.AV_CODEC_ID_AAC) orelse return error.DecoderNotFound;
    var dec_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&dec_ctx);
    dec_ctx.*.sample_rate = 48000;
    c.av_channel_layout_default(&dec_ctx.*.ch_layout, 2);
    if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.DecoderOpenFailed;

    var dec_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&dec_pkt));
    var dec_frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(@ptrCast(&dec_frame));

    for (frames.items) |f| {
        const adts = aac_enc.AacEncoder.buildAdtsHeader(f.data.len, 48000, 2);
        var full_buf: [4096]u8 = undefined;
        @memcpy(full_buf[0..7], &adts);
        @memcpy(full_buf[7 .. 7 + f.data.len], f.data);
        dec_pkt.*.data = @ptrCast(&full_buf);
        dec_pkt.*.size = @intCast(7 + f.data.len);
        const send_ret = c.avcodec_send_packet(dec_ctx, dec_pkt);
        try testing.expectEqual(@as(c_int, 0), send_ret);
        _ = c.avcodec_receive_frame(dec_ctx, dec_frame);
    }
}

test "StreamAudioTranscoder decodes 6-channel EAC3 from Reacher.mkv and encodes to stereo AAC" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_file = "tests/Reacher.mkv";

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&in_fmt_ctx, test_file, null, null) < 0) return;
    defer c.avformat_close_input(&in_fmt_ctx);

    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    var audio_stream_idx: usize = 0;
    var audio_stream: *c.AVStream = undefined;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            audio_stream_idx = i;
            audio_stream = in_fmt_ctx.?.streams[i];
            break;
        }
    }

    const extradata_slice: ?[]const u8 = if (audio_stream.*.codecpar.*.extradata_size > 0)
        audio_stream.*.codecpar.*.extradata[0..@intCast(audio_stream.*.codecpar.*.extradata_size)]
    else
        null;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_EAC3", extradata_slice, 6, 48000, true);
    defer transcoder.deinit();

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == audio_stream_idx) {
            const raw_data: []const u8 = pkt.*.data[0..@intCast(pkt.*.size)];
            try transcoder.transcodePacket(allocator, raw_data, &frames);
            if (frames.items.len >= 5) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len >= 5);

    const dec = c.avcodec_find_decoder(c.AV_CODEC_ID_AAC) orelse return error.DecoderNotFound;
    var dec_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&dec_ctx);
    dec_ctx.*.sample_rate = 48000;
    c.av_channel_layout_default(&dec_ctx.*.ch_layout, 2);
    if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.DecoderOpenFailed;

    var dec_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&dec_pkt));
    var dec_frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(@ptrCast(&dec_frame));

    for (frames.items) |f| {
        const adts = aac_enc.AacEncoder.buildAdtsHeader(f.data.len, 48000, 2);
        var full_buf: [4096]u8 = undefined;
        @memcpy(full_buf[0..7], &adts);
        @memcpy(full_buf[7 .. 7 + f.data.len], f.data);
        dec_pkt.*.data = @ptrCast(&full_buf);
        dec_pkt.*.size = @intCast(7 + f.data.len);
        const send_ret = c.avcodec_send_packet(dec_ctx, dec_pkt);
        try testing.expectEqual(@as(c_int, 0), send_ret);
        _ = c.avcodec_receive_frame(dec_ctx, dec_frame);
    }
}

test "StreamAudioTranscoder decodes 6-channel AAC from Tuner.mkv and downmixes/encodes to stereo AAC" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_file = "tests/Tuner.mkv";

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&in_fmt_ctx, test_file, null, null) < 0) return;
    defer c.avformat_close_input(&in_fmt_ctx);

    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    var audio_stream_idx: usize = 0;
    var audio_stream: *c.AVStream = undefined;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            audio_stream_idx = i;
            audio_stream = in_fmt_ctx.?.streams[i];
            break;
        }
    }

    const extradata_slice: ?[]const u8 = if (audio_stream.*.codecpar.*.extradata_size > 0)
        audio_stream.*.codecpar.*.extradata[0..@intCast(audio_stream.*.codecpar.*.extradata_size)]
    else
        null;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AAC", extradata_slice, 6, 48000, true);
    defer transcoder.deinit();

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == audio_stream_idx) {
            const raw_data: []const u8 = pkt.*.data[0..@intCast(pkt.*.size)];
            try transcoder.transcodePacket(allocator, raw_data, &frames);
            if (frames.items.len >= 5) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len >= 5);

    const dec = c.avcodec_find_decoder(c.AV_CODEC_ID_AAC) orelse return error.DecoderNotFound;
    var dec_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&dec_ctx);
    dec_ctx.*.sample_rate = 48000;
    c.av_channel_layout_default(&dec_ctx.*.ch_layout, 2);
    if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.DecoderOpenFailed;

    var dec_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&dec_pkt));
    var dec_frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(@ptrCast(&dec_frame));

    for (frames.items) |f| {
        const adts = aac_enc.AacEncoder.buildAdtsHeader(f.data.len, 48000, 2);
        var full_buf: [4096]u8 = undefined;
        @memcpy(full_buf[0..7], &adts);
        @memcpy(full_buf[7 .. 7 + f.data.len], f.data);
        dec_pkt.*.data = @ptrCast(&full_buf);
        dec_pkt.*.size = @intCast(7 + f.data.len);
        const send_ret = c.avcodec_send_packet(dec_ctx, dec_pkt);
        try testing.expectEqual(@as(c_int, 0), send_ret);
        _ = c.avcodec_receive_frame(dec_ctx, dec_frame);
    }
}

test "StreamAudioTranscoder decodes 6-channel AC3 from Polly.mkv and encodes to stereo AAC" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const test_file = "tests/Polly.mkv";

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    if (c.avformat_open_input(&in_fmt_ctx, test_file, null, null) < 0) return;
    defer c.avformat_close_input(&in_fmt_ctx);

    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.StreamInfoFailed;

    var audio_stream_idx: usize = 0;
    var audio_stream: *c.AVStream = undefined;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            audio_stream_idx = i;
            audio_stream = in_fmt_ctx.?.streams[i];
            break;
        }
    }

    const extradata_slice: ?[]const u8 = if (audio_stream.*.codecpar.*.extradata_size > 0)
        audio_stream.*.codecpar.*.extradata[0..@intCast(audio_stream.*.codecpar.*.extradata_size)]
    else
        null;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", extradata_slice, 6, 48000, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.native_ac3_dec != null);

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == audio_stream_idx) {
            const raw_data: []const u8 = pkt.*.data[0..@intCast(pkt.*.size)];
            try transcoder.transcodePacket(allocator, raw_data, &frames);
            if (frames.items.len >= 5) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len >= 5);

    const dec = c.avcodec_find_decoder(c.AV_CODEC_ID_AAC) orelse return error.DecoderNotFound;
    var dec_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&dec_ctx);
    dec_ctx.*.sample_rate = 48000;
    c.av_channel_layout_default(&dec_ctx.*.ch_layout, 2);
    if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.DecoderOpenFailed;

    var dec_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&dec_pkt));
    var dec_frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(@ptrCast(&dec_frame));

    for (frames.items) |f| {
        const adts = aac_enc.AacEncoder.buildAdtsHeader(f.data.len, 48000, 2);
        var full_buf: [4096]u8 = undefined;
        @memcpy(full_buf[0..7], &adts);
        @memcpy(full_buf[7 .. 7 + f.data.len], f.data);
        dec_pkt.*.data = @ptrCast(&full_buf);
        dec_pkt.*.size = @intCast(7 + f.data.len);
        const send_ret = c.avcodec_send_packet(dec_ctx, dec_pkt);
        try testing.expectEqual(@as(c_int, 0), send_ret);
        _ = c.avcodec_receive_frame(dec_ctx, dec_frame);
    }
}

test "Inspect native AAC roundtrip decoded PCM levels" {
    const testing = std.testing;
    const file = std.Io.Dir.cwd().openFile(testing.io, "tmp/polly_5s.ac3", .{}) catch return;
    defer file.close(testing.io);

    var buf: [15360]u8 = undefined;
    var reader = file.reader(testing.io, &buf);
    _ = try reader.interface.readSliceShort(&buf);

    var ac3 = ac3_dec.Ac3Decoder.init();
    var encoder = aac_enc.AacEncoder.init(48000, 192000);

    var full_pcm_l: [15360]f32 = undefined;
    var full_pcm_r: [15360]f32 = undefined;

    for (0..10) |f| {
        const in_bytes = buf[f * 1536 .. (f + 1) * 1536];
        var stereo: [1536 * 2]f32 = undefined;
        _ = try ac3.decodeFrame(in_bytes, &stereo);
        for (0..1536) |i| {
            full_pcm_l[f * 1536 + i] = stereo[i * 2 + 0];
            full_pcm_r[f * 1536 + i] = stereo[i * 2 + 1];
        }
    }

    var max_in_pcm: f32 = 0.0;
    for (full_pcm_l) |s| max_in_pcm = @max(max_in_pcm, @abs(s));

    const dec = c.avcodec_find_decoder(c.AV_CODEC_ID_AAC) orelse return error.DecoderNotFound;
    var dec_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&dec_ctx);
    dec_ctx.*.sample_rate = 48000;
    c.av_channel_layout_default(&dec_ctx.*.ch_layout, 2);
    if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.DecoderOpenFailed;

    var dec_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&dec_pkt));
    var dec_frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(@ptrCast(&dec_frame));

    var max_out_pcm: f32 = 0.0;
    var num_decoded_frames: usize = 0;

    for (0..14) |f| {
        const start = f * 1024;
        const l = full_pcm_l[start .. start + 1024];
        const r = full_pcm_r[start .. start + 1024];

        var aac_buf: [2048]u8 = undefined;
        const aac_len = try encoder.encodeFrame(l, r, &aac_buf);

        const adts = aac_enc.AacEncoder.buildAdtsHeader(aac_len, 48000, 2);
        var full_buf: [4096]u8 = undefined;
        @memcpy(full_buf[0..7], &adts);
        @memcpy(full_buf[7 .. 7 + aac_len], aac_buf[0..aac_len]);

        dec_pkt.*.data = @ptrCast(&full_buf);
        dec_pkt.*.size = @intCast(7 + aac_len);

        _ = c.avcodec_send_packet(dec_ctx, dec_pkt);

        while (c.avcodec_receive_frame(dec_ctx, dec_frame) >= 0) {
            num_decoded_frames += 1;
            const nb_samples: usize = @intCast(dec_frame.*.nb_samples);
            const fltp_data = @as([*c][*c]f32, @ptrCast(&dec_frame.*.data));
            const decoded_l = fltp_data[0][0..nb_samples];
            for (decoded_l) |s| {
                max_out_pcm = @max(max_out_pcm, @abs(s));
            }
        }
    }

    try testing.expect(num_decoded_frames >= 10);
    try testing.expect(max_out_pcm > 0.01);
}

test {
    std.testing.refAllDecls(aac_enc);
    std.testing.refAllDecls(ac3_dec);
}
