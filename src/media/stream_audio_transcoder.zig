const std = @import("std");
pub const c = @import("../core/c.zig").c;
pub const ac3_dec = @import("native/audio/ac3_dec.zig");
pub const eac3_dec = @import("native/audio/eac3_dec.zig");
pub const aac_dec = @import("native/audio/aac_dec.zig");
pub const aac_enc = @import("native/audio/aac_enc.zig");
pub const audio_fifo = @import("native/audio/fifo.zig");

pub const EncodedAacFrame = struct {
    data: []u8,
    sample_count: u32 = 1024,
};

/// Encapsulates FFmpeg decoding, resampling, and encoding context for codecs
/// not yet natively supported in pure Zig (e.g. E-AC-3, DTS, multichannel AAC, etc.).
pub const FfmpegAudioState = struct {
    decode_ctx: *c.AVCodecContext,
    encode_ctx: ?*c.AVCodecContext = null,
    swr_ctx: ?*c.SwrContext = null,
    fifo: ?*c.AVAudioFifo = null,
    frame_in: *c.AVFrame,
    frame_out: ?*c.AVFrame = null,
    in_pkt: *c.AVPacket,
    out_pkt: ?*c.AVPacket = null,
    pts_counter: i64 = 0,
    swr_in_channels: i32 = 0,
    swr_in_rate: i32 = 0,
    swr_in_fmt: c.AVSampleFormat = c.AV_SAMPLE_FMT_NONE,

    pub fn init(
        allocator: std.mem.Allocator,
        av_codec_id: c.AVCodecID,
        codec_private: ?[]const u8,
        channels: u16,
        sample_rate: u32,
        use_native_encoder: bool,
    ) !*FfmpegAudioState {
        const dec = c.avcodec_find_decoder(av_codec_id) orelse return error.DecoderNotFound;

        var self = try allocator.create(FfmpegAudioState);
        errdefer allocator.destroy(self);

        self.* = .{
            .decode_ctx = undefined,
            .encode_ctx = null,
            .swr_ctx = null,
            .fifo = null,
            .frame_in = undefined,
            .frame_out = null,
            .in_pkt = undefined,
            .out_pkt = null,
            .pts_counter = 0,
            .swr_in_channels = 0,
            .swr_in_rate = 0,
            .swr_in_fmt = c.AV_SAMPLE_FMT_NONE,
        };

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

        self.frame_in = c.av_frame_alloc() orelse return error.OutOfMemory;
        errdefer c.av_frame_free(@ptrCast(&self.frame_in));

        self.in_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
        errdefer c.av_packet_free(@ptrCast(&self.in_pkt));

        // If not using native encoder, setup FFmpeg's AAC encoder and C FIFO
        if (!use_native_encoder) {
            const enc = c.avcodec_find_encoder(c.AV_CODEC_ID_AAC) orelse return error.EncoderNotFound;
            self.encode_ctx = c.avcodec_alloc_context3(enc) orelse return error.OutOfMemory;
            errdefer c.avcodec_free_context(@ptrCast(&self.encode_ctx));

            if (@hasDecl(c, "av_channel_layout_default")) {
                c.av_channel_layout_default(&self.encode_ctx.?.ch_layout, 2);
            } else {
                self.encode_ctx.?.channels = 2;
                self.encode_ctx.?.channel_layout = c.AV_CH_LAYOUT_STEREO;
            }
            self.encode_ctx.?.sample_rate = 48000;
            self.encode_ctx.?.sample_fmt = c.AV_SAMPLE_FMT_FLTP;
            self.encode_ctx.?.bit_rate = 192000;
            self.encode_ctx.?.time_base = c.AVRational{ .num = 1, .den = 48000 };

            if (c.avcodec_open2(self.encode_ctx.?, enc, null) < 0) return error.EncoderOpenError;

            self.fifo = c.av_audio_fifo_alloc(self.encode_ctx.?.sample_fmt, 2, 1024) orelse return error.OutOfMemory;
            errdefer c.av_audio_fifo_free(self.fifo.?);

            self.frame_out = c.av_frame_alloc() orelse return error.OutOfMemory;
            errdefer c.av_frame_free(@ptrCast(&self.frame_out));

            self.frame_out.?.nb_samples = self.encode_ctx.?.frame_size;
            if (@hasDecl(c, "av_channel_layout_copy")) {
                _ = c.av_channel_layout_copy(&self.frame_out.?.ch_layout, &self.encode_ctx.?.ch_layout);
            } else {
                self.frame_out.?.channel_layout = self.encode_ctx.?.channel_layout;
                self.frame_out.?.channels = self.encode_ctx.?.channels;
            }
            self.frame_out.?.format = self.encode_ctx.?.sample_fmt;
            self.frame_out.?.sample_rate = self.encode_ctx.?.sample_rate;
            if (c.av_frame_get_buffer(self.frame_out.?, 0) < 0) return error.OutOfMemory;

            self.out_pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
            errdefer c.av_packet_free(@ptrCast(&self.out_pkt));
        }

        return self;
    }

    pub fn initOrUpdateSwr(self: *FfmpegAudioState) !void {
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
            var out_ch_layout: c.AVChannelLayout = undefined;
            c.av_channel_layout_default(&out_ch_layout, 2);
            if (c.swr_alloc_set_opts2(
                @ptrCast(&self.swr_ctx),
                &out_ch_layout,
                c.AV_SAMPLE_FMT_FLTP,
                48000,
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
                c.AV_SAMPLE_FMT_FLTP,
                48000,
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

    pub fn deinit(self: *FfmpegAudioState) void {
        c.av_packet_free(@ptrCast(&self.in_pkt));
        if (self.out_pkt) |*pkt| c.av_packet_free(@ptrCast(pkt));
        c.av_frame_free(@ptrCast(&self.frame_in));
        if (self.frame_out) |*frame| c.av_frame_free(@ptrCast(frame));
        if (self.fifo) |fifo| c.av_audio_fifo_free(fifo);
        if (self.swr_ctx) |swr| {
            var temp_swr: ?*c.SwrContext = swr;
            c.swr_free(@ptrCast(&temp_swr));
            self.swr_ctx = null;
        }
        if (self.encode_ctx) |*ctx| c.avcodec_free_context(@ptrCast(ctx));
        c.avcodec_free_context(@ptrCast(&self.decode_ctx));
    }
};

/// Standalone audio transcoder that converts compressed audio packets (AC-3, DTS, E-AC-3, multichannel AAC)
/// into standardized 48kHz Stereo AAC frames for native fMP4 container muxing.
/// For AC-3, E-AC-3, and Multichannel AAC, it operates 100% in pure Zig with zero FFmpeg dependencies.
pub const StreamAudioTranscoder = struct {
    is_pure_native: bool,
    native_fifo: audio_fifo.AudioFifo,
    native_aac_enc: aac_enc.AacEncoder,
    native_ac3_dec: ?ac3_dec.Ac3Decoder = null,
    native_eac3_dec: ?eac3_dec.Eac3Decoder = null,
    native_aac_dec: ?aac_dec.AacDecoder = null,
    use_native_encoder: bool = true,
    ffmpeg_state: ?*FfmpegAudioState = null,

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

    pub fn isNativeSupportedCodec(codec_name: []const u8) bool {
        return std.mem.eql(u8, codec_name, "A_AC3") or
            std.mem.eql(u8, codec_name, "ac-3") or
            std.mem.eql(u8, codec_name, "sac3") or
            std.mem.eql(u8, codec_name, "A_EAC3") or
            std.mem.eql(u8, codec_name, "ec-3") or
            std.mem.eql(u8, codec_name, "A_AAC") or
            std.mem.eql(u8, codec_name, "mp4a");
    }

    pub fn initFromCodec(
        codec_name: []const u8,
        codec_private: ?[]const u8,
        channels: u16,
        sample_rate: u32,
        use_native_encoder: bool,
    ) !*StreamAudioTranscoder {
        const allocator = std.heap.c_allocator;
        const is_ac3 = std.mem.eql(u8, codec_name, "A_AC3") or std.mem.eql(u8, codec_name, "ac-3") or std.mem.eql(u8, codec_name, "sac3");
        const is_eac3 = std.mem.eql(u8, codec_name, "A_EAC3") or std.mem.eql(u8, codec_name, "ec-3");
        const is_aac = std.mem.eql(u8, codec_name, "A_AAC") or std.mem.eql(u8, codec_name, "mp4a");

        // 100% Pure Zig pipeline for AC-3, E-AC-3, and AAC: no FFmpeg contexts, FIFOs, frames, or packets
        if (use_native_encoder and (is_ac3 or is_eac3 or is_aac)) {
            const self = try allocator.create(StreamAudioTranscoder);
            errdefer allocator.destroy(self);

            var aac_dec_inst: ?aac_dec.AacDecoder = null;
            if (is_aac) {
                var d = aac_dec.AacDecoder.init();
                d.sample_rate = sample_rate;
                d.channels = channels;
                aac_dec_inst = d;
            }

            self.* = .{
                .is_pure_native = true,
                .native_fifo = audio_fifo.AudioFifo.init(allocator),
                .native_aac_enc = aac_enc.AacEncoder.init(48000, 192000),
                .native_ac3_dec = if (is_ac3) ac3_dec.Ac3Decoder.init() else null,
                .native_eac3_dec = if (is_eac3) eac3_dec.Eac3Decoder.init() else null,
                .native_aac_dec = aac_dec_inst,
                .use_native_encoder = true,
                .ffmpeg_state = null,
            };
            return self;
        }

        // Fallback pipeline: delegate decoding/resampling to FFmpeg
        const av_codec_id = mapCodecId(codec_name) orelse return error.UnsupportedAudioCodec;
        var ff_state = try FfmpegAudioState.init(allocator, av_codec_id, codec_private, channels, sample_rate, use_native_encoder);
        errdefer {
            ff_state.deinit();
            allocator.destroy(ff_state);
        }

        const self = try allocator.create(StreamAudioTranscoder);
        errdefer allocator.destroy(self);

        self.* = .{
            .is_pure_native = false,
            .native_fifo = audio_fifo.AudioFifo.init(allocator),
            .native_aac_enc = aac_enc.AacEncoder.init(48000, 192000),
            .native_ac3_dec = null,
            .use_native_encoder = use_native_encoder,
            .ffmpeg_state = ff_state,
        };
        return self;
    }

    /// Feeds a raw audio packet from demuxer into the transcoder and collects any ready AAC frames.
    pub fn transcodePacket(
        self: *StreamAudioTranscoder,
        allocator: std.mem.Allocator,
        raw_payload: []const u8,
        out_frames: *std.ArrayList(EncodedAacFrame),
    ) !void {
        // Pure Zig AC-3 decoding path
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
                        try self.native_fifo.write(planar_l[0..n_samples], planar_r[0..n_samples]);
                        decoded_any = true;
                    }
                } else |_| {}
                offset += frame_size;
            }
            if (decoded_any) {
                try self.drainNativeFifo(allocator, out_frames);
            }
            return;
        }

        // Pure Zig E-AC-3 decoding path
        if (self.native_eac3_dec) |*eac3| {
            var offset: usize = 0;
            var decoded_any = false;
            while (offset + 6 <= raw_payload.len) {
                if (raw_payload[offset] != 0x0B or raw_payload[offset + 1] != 0x77) {
                    offset += 1;
                    continue;
                }
                const frmsiz: usize = (@as(usize, raw_payload[offset + 2] & 0x07) << 8) | @as(usize, raw_payload[offset + 3]);
                const frame_size = (frmsiz + 1) * 2;
                if (frame_size < 6 or offset + frame_size > raw_payload.len) {
                    offset += 2;
                    continue;
                }

                const frame_bytes = raw_payload[offset .. offset + frame_size];
                var stereo_interleaved: [1536 * 2]f32 = undefined;
                if (eac3.decodeFrame(frame_bytes, &stereo_interleaved)) |n_samples| {
                    if (n_samples > 0) {
                        var planar_l: [1536]f32 = undefined;
                        var planar_r: [1536]f32 = undefined;
                        for (0..n_samples) |i| {
                            planar_l[i] = stereo_interleaved[i * 2 + 0];
                            planar_r[i] = stereo_interleaved[i * 2 + 1];
                        }
                        try self.native_fifo.write(planar_l[0..n_samples], planar_r[0..n_samples]);
                        decoded_any = true;
                    }
                } else |_| {}
                offset += frame_size;
            }
            if (decoded_any) {
                try self.drainNativeFifo(allocator, out_frames);
            }
            return;
        }

        // Pure Zig AAC decoding path
        if (self.native_aac_dec) |*aac| {
            var stereo_interleaved: [1024 * 2]f32 = undefined;
            if (aac.decodeFrame(raw_payload, &stereo_interleaved)) |n_samples| {
                if (n_samples > 0) {
                    var planar_l: [1024]f32 = undefined;
                    var planar_r: [1024]f32 = undefined;
                    for (0..n_samples) |i| {
                        planar_l[i] = stereo_interleaved[i * 2 + 0];
                        planar_r[i] = stereo_interleaved[i * 2 + 1];
                    }
                    try self.native_fifo.write(planar_l[0..n_samples], planar_r[0..n_samples]);
                    try self.drainNativeFifo(allocator, out_frames);
                }
            } else |_| {}
            return;
        }

        // FFmpeg decoding fallback
        const ff = self.ffmpeg_state orelse return error.FfmpegStateMissing;

        c.av_packet_unref(ff.in_pkt);
        ff.in_pkt.*.data = @constCast(raw_payload.ptr);
        ff.in_pkt.*.size = @intCast(raw_payload.len);

        if (c.avcodec_send_packet(ff.decode_ctx, ff.in_pkt) < 0) return;

        while (c.avcodec_receive_frame(ff.decode_ctx, ff.frame_in) >= 0) {
            try ff.initOrUpdateSwr();

            var conv_buf: [2][4096]f32 = undefined;
            var out_ptrs = [_][*c]u8{ @ptrCast(&conv_buf[0]), @ptrCast(&conv_buf[1]) };

            const in_data = @as([*c][*c]const u8, @ptrCast(&ff.frame_in.*.data));
            const real_out_samples = c.swr_convert(ff.swr_ctx.?, &out_ptrs, 4096, in_data, ff.frame_in.*.nb_samples);
            if (real_out_samples > 0) {
                const out_count: usize = @intCast(real_out_samples);
                if (self.use_native_encoder) {
                    try self.native_fifo.write(conv_buf[0][0..out_count], conv_buf[1][0..out_count]);
                } else if (ff.fifo) |fifo| {
                    _ = c.av_audio_fifo_write(fifo, @ptrCast(&out_ptrs), real_out_samples);
                }
            }
        }

        if (self.use_native_encoder) {
            try self.drainNativeFifo(allocator, out_frames);
        } else {
            try self.drainFfmpegFifo(allocator, out_frames);
        }
    }

    fn drainNativeFifo(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
        while (self.native_fifo.size() >= 1024) {
            var planar_l: [1024]f32 = undefined;
            var planar_r: [1024]f32 = undefined;
            _ = self.native_fifo.read(&planar_l, &planar_r);

            var aac_frame_buf: [8192]u8 = undefined;
            const aac_len = try self.native_aac_enc.encodeFrame(&planar_l, &planar_r, &aac_frame_buf);

            const frame_buf = try allocator.alloc(u8, aac_len);
            errdefer allocator.free(frame_buf);
            @memcpy(frame_buf, aac_frame_buf[0..aac_len]);

            try out_frames.append(allocator, EncodedAacFrame{
                .data = frame_buf,
                .sample_count = 1024,
            });
        }
    }

    fn drainFfmpegFifo(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
        const ff = self.ffmpeg_state orelse return;
        const fifo = ff.fifo orelse return;
        const enc_ctx = ff.encode_ctx orelse return;
        const frame_out = ff.frame_out orelse return;
        const out_pkt = ff.out_pkt orelse return;

        while (c.av_audio_fifo_size(fifo) >= enc_ctx.*.frame_size) {
            _ = c.av_audio_fifo_read(fifo, @ptrCast(&frame_out.*.data), enc_ctx.*.frame_size);
            frame_out.*.pts = ff.pts_counter;
            ff.pts_counter += frame_out.*.nb_samples;

            if (c.avcodec_send_frame(enc_ctx, frame_out) < 0) return;

            while (c.avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                defer c.av_packet_unref(out_pkt);
                const aac_len: usize = @intCast(out_pkt.*.size);
                const frame_buf = try allocator.alloc(u8, aac_len);
                errdefer allocator.free(frame_buf);
                @memcpy(frame_buf, out_pkt.*.data[0..aac_len]);

                try out_frames.append(allocator, EncodedAacFrame{
                    .data = frame_buf,
                    .sample_count = 1024,
                });
            }
        }
    }

    /// Flushes any remaining samples in the FIFO and encoder queue.
    pub fn flush(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
        if (self.use_native_encoder) {
            const remaining_samples = self.native_fifo.size();
            if (remaining_samples > 0) {
                var planar_l: [1024]f32 = undefined;
                var planar_r: [1024]f32 = undefined;
                @memset(&planar_l, 0.0);
                @memset(&planar_r, 0.0);
                _ = self.native_fifo.read(&planar_l, &planar_r);

                var aac_frame_buf: [2048]u8 = undefined;
                const aac_len = try self.native_aac_enc.encodeFrame(&planar_l, &planar_r, &aac_frame_buf);

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

        const ff = self.ffmpeg_state orelse return;
        const fifo = ff.fifo orelse return;
        const enc_ctx = ff.encode_ctx orelse return;
        const frame_out = ff.frame_out orelse return;
        const out_pkt = ff.out_pkt orelse return;

        const remaining_samples = c.av_audio_fifo_size(fifo);
        if (remaining_samples > 0) {
            @memset(frame_out.*.data[0][0 .. @intCast(enc_ctx.*.frame_size * 4)], 0);
            @memset(frame_out.*.data[1][0 .. @intCast(enc_ctx.*.frame_size * 4)], 0);
            _ = c.av_audio_fifo_read(fifo, @ptrCast(&frame_out.*.data), remaining_samples);
            frame_out.*.pts = ff.pts_counter;
            ff.pts_counter += frame_out.*.nb_samples;

            _ = c.avcodec_send_frame(enc_ctx, frame_out);
            while (c.avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                defer c.av_packet_unref(out_pkt);
                const aac_len: usize = @intCast(out_pkt.*.size);
                const frame_buf = try allocator.alloc(u8, aac_len);
                errdefer allocator.free(frame_buf);
                @memcpy(frame_buf, out_pkt.*.data[0..aac_len]);

                try out_frames.append(allocator, EncodedAacFrame{
                    .data = frame_buf,
                    .sample_count = 1024,
                });
            }
        }

        _ = c.avcodec_send_frame(enc_ctx, null);
        while (c.avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
            defer c.av_packet_unref(out_pkt);
            const aac_len: usize = @intCast(out_pkt.*.size);
            const frame_buf = try allocator.alloc(u8, aac_len);
            errdefer allocator.free(frame_buf);
            @memcpy(frame_buf, out_pkt.*.data[0..aac_len]);

            try out_frames.append(allocator, EncodedAacFrame{
                .data = frame_buf,
                .sample_count = 1024,
            });
        }
    }

    pub fn deinit(self: *StreamAudioTranscoder) void {
        self.native_fifo.deinit();
        if (self.ffmpeg_state) |ff| {
            ff.deinit();
            std.heap.c_allocator.destroy(ff);
            self.ffmpeg_state = null;
        }
        std.heap.c_allocator.destroy(self);
    }
};

test "StreamAudioTranscoder AC-3 native mode allocates zero FFmpeg contexts" {
    const testing = std.testing;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 6, 48000, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.ffmpeg_state == null);
    try testing.expect(transcoder.native_ac3_dec != null);
    try testing.expectEqual(@as(usize, 0), transcoder.native_fifo.size());
}

test "StreamAudioTranscoder pure Zig AC-3 transcode end-to-end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const file = std.Io.Dir.cwd().openFile(testing.io, "tmp/polly_5s.ac3", .{}) catch return;
    defer file.close(testing.io);

    var buf: [15360]u8 = undefined;
    var reader_file = file.reader(testing.io, &buf);
    const bytes_read = try reader_file.interface.readSliceShort(&buf);

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 6, 48000, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.ffmpeg_state == null);

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    try transcoder.transcodePacket(allocator, buf[0..bytes_read], &frames);
    try transcoder.flush(allocator, &frames);

    try testing.expect(frames.items.len > 0);
    for (frames.items) |f| {
        try testing.expect(f.data.len > 0);
        try testing.expectEqual(@as(u32, 1024), f.sample_count);
    }
}
