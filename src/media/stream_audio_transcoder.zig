const std = @import("std");
pub const c = @import("../core/c.zig").c;
pub const ac3_dec = @import("native/audio/ac3_dec.zig");
pub const aac_enc = @import("native/audio/aac_enc.zig");

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
