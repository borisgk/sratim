const std = @import("std");
const c = @import("../core/c.zig").c;

/// Encapsulates FFmpeg decoding, resampling, and encoding context for codecs
/// not yet natively supported in pure Zig (e.g. DTS, fallback pipelines, etc.).
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
