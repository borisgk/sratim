const std = @import("std");
const c = @import("../core/c.zig").c;

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
        self.encode_ctx.*.sample_fmt = enc.*.sample_fmts[0];
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
            const encode_cl = if (self.encode_ctx.*.channel_layout == 0) c.av_get_default_channel_layout(self.encode_ctx.*.channels) else self.encode_ctx.*.channel_layout;
            const decode_cl = if (self.decode_ctx.*.channel_layout == 0) c.av_get_default_channel_layout(self.decode_ctx.*.channels) else self.decode_ctx.*.channel_layout;
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
            const out_samples = c.av_rescale_rnd(
                c.swr_get_delay(self.swr_ctx.?, self.decode_ctx.*.sample_rate) + self.frame_in.*.nb_samples,
                self.encode_ctx.*.sample_rate,
                self.decode_ctx.*.sample_rate,
                c.AV_ROUND_UP,
            );
            
            var converted_frame = c.av_frame_alloc() orelse return error.OutOfMemory;
            defer c.av_frame_free(@ptrCast(&converted_frame));
            if (@hasDecl(c, "av_channel_layout_copy")) {
                _ = c.av_channel_layout_copy(&converted_frame.*.ch_layout, &self.encode_ctx.*.ch_layout);
            } else {
                converted_frame.*.channel_layout = self.encode_ctx.*.channel_layout;
                converted_frame.*.channels = self.encode_ctx.*.channels;
            }
            converted_frame.*.sample_rate = self.encode_ctx.*.sample_rate;
            converted_frame.*.format = self.encode_ctx.*.sample_fmt;
            converted_frame.*.nb_samples = @intCast(out_samples);
            if (c.av_frame_get_buffer(converted_frame, 0) < 0) return error.OutOfMemory;

            const in_data = @as([*c][*c]const u8, @ptrCast(&self.frame_in.*.data));
            const out_data = @as([*c][*c]u8, @ptrCast(&converted_frame.*.data));
            
            const real_out_samples = c.swr_convert(self.swr_ctx.?, out_data, @intCast(out_samples), in_data, self.frame_in.*.nb_samples);
            if (real_out_samples > 0) {
                _ = c.av_audio_fifo_write(self.fifo, @ptrCast(out_data), real_out_samples);
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

test "AudioTranscoder preserves initial PTS" {
    const testing = std.testing;

    const path = "tests/test_sync.mkv";
    std.fs.cwd().access(path, .{}) catch return;

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
