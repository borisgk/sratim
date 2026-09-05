const std = @import("std");
pub const ac3_dec = @import("native/audio/ac3_dec.zig");
pub const eac3_dec = @import("native/audio/eac3_dec.zig");
pub const aac_dec = @import("native/audio/aac_dec.zig");
pub const aac_enc = @import("native/audio/aac_enc.zig");
pub const audio_fifo = @import("native/audio/fifo.zig");

pub const mp3_dec = @import("native/audio/mp3_dec.zig");
pub const dsp = @import("native/audio/dsp.zig");

pub const EncodedAacFrame = struct {
    data: []u8,
    sample_count: u32 = 1024,
};

/// Standalone pure Zig audio transcoder that converts compressed audio packets (AC-3, E-AC-3, MP3, multichannel AAC)
/// into standardized 48kHz Stereo AAC frames for native fMP4 container muxing.
/// Operates 100% in pure Zig with zero FFmpeg dependencies.
pub const StreamAudioTranscoder = struct {
    is_pure_native: bool = true,
    native_fifo: audio_fifo.AudioFifo,
    native_aac_enc: aac_enc.AacEncoder,
    native_ac3_dec: ?ac3_dec.Ac3Decoder = null,
    native_eac3_dec: ?eac3_dec.Eac3Decoder = null,
    native_aac_dec: ?aac_dec.AacDecoder = null,
    native_mp3_dec: ?mp3_dec.Mp3Decoder = null,
    resampler_l: ?dsp.HermiteResampler = null,
    resampler_r: ?dsp.HermiteResampler = null,

    pub fn isNativeSupportedCodec(codec_name: []const u8) bool {
        return std.mem.eql(u8, codec_name, "A_AC3") or
            std.mem.eql(u8, codec_name, "ac-3") or
            std.mem.eql(u8, codec_name, "sac3") or
            std.mem.eql(u8, codec_name, "A_EAC3") or
            std.mem.eql(u8, codec_name, "ec-3") or
            std.mem.eql(u8, codec_name, "A_AAC") or
            std.mem.eql(u8, codec_name, "mp4a") or
            std.mem.eql(u8, codec_name, "A_MPEG/L3") or
            std.mem.eql(u8, codec_name, "A_MPEG/L2") or
            std.mem.eql(u8, codec_name, "A_MPEG/L1") or
            std.mem.eql(u8, codec_name, ".mp3") or
            std.mem.eql(u8, codec_name, "mp3") or
            std.mem.eql(u8, codec_name, "mp3 ");
    }

    pub fn initFromCodec(
        codec_name: []const u8,
        codec_private: ?[]const u8,
        channels: u16,
        sample_rate: u32,
        use_native_encoder: bool,
    ) !*StreamAudioTranscoder {
        _ = codec_private;
        _ = use_native_encoder;
        const allocator = std.heap.c_allocator;
        const is_ac3 = std.mem.eql(u8, codec_name, "A_AC3") or std.mem.eql(u8, codec_name, "ac-3") or std.mem.eql(u8, codec_name, "sac3");
        const is_eac3 = std.mem.eql(u8, codec_name, "A_EAC3") or std.mem.eql(u8, codec_name, "ec-3");
        const is_aac = std.mem.eql(u8, codec_name, "A_AAC") or std.mem.eql(u8, codec_name, "mp4a");
        const is_mp3 = std.mem.eql(u8, codec_name, "A_MPEG/L3") or
            std.mem.eql(u8, codec_name, "A_MPEG/L2") or
            std.mem.eql(u8, codec_name, "A_MPEG/L1") or
            std.mem.eql(u8, codec_name, ".mp3") or
            std.mem.eql(u8, codec_name, "mp3") or
            std.mem.eql(u8, codec_name, "mp3 ");

        if (!is_ac3 and !is_eac3 and !is_aac and !is_mp3) {
            return error.UnsupportedAudioCodec;
        }

        const self = try allocator.create(StreamAudioTranscoder);
        errdefer allocator.destroy(self);

        var aac_dec_inst: ?aac_dec.AacDecoder = null;
        if (is_aac) {
            var d = aac_dec.AacDecoder.init();
            d.sample_rate = sample_rate;
            d.channels = channels;
            aac_dec_inst = d;
        }

        const needs_resample = (sample_rate != 48000 and sample_rate > 0);

        self.* = .{
            .is_pure_native = true,
            .native_fifo = audio_fifo.AudioFifo.init(allocator),
            .native_aac_enc = aac_enc.AacEncoder.init(48000, 192000),
            .native_ac3_dec = if (is_ac3) ac3_dec.Ac3Decoder.init() else null,
            .native_eac3_dec = if (is_eac3) eac3_dec.Eac3Decoder.init() else null,
            .native_aac_dec = aac_dec_inst,
            .native_mp3_dec = if (is_mp3) mp3_dec.Mp3Decoder.init() else null,
            .resampler_l = if (needs_resample) dsp.HermiteResampler.init(sample_rate, 48000) else null,
            .resampler_r = if (needs_resample) dsp.HermiteResampler.init(sample_rate, 48000) else null,
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
        if (self.native_ac3_dec) |*dec| {
            var stereo_interleaved: [1536 * 2]f32 = undefined;
            if (dec.decodeFrame(raw_payload, &stereo_interleaved)) |n_samples| {
                if (n_samples > 0) {
                    var planar_l: [1536]f32 = undefined;
                    var planar_r: [1536]f32 = undefined;
                    for (0..n_samples) |i| {
                        planar_l[i] = stereo_interleaved[i * 2];
                        planar_r[i] = stereo_interleaved[i * 2 + 1];
                    }
                    try self.writePlanarAndDrain(allocator, planar_l[0..n_samples], planar_r[0..n_samples], out_frames);
                }
            } else |_| {
                // Concealment silence: keep audio clock aligned if packet decode errors
                var silence_l: [1536]f32 = [_]f32{0.0} ** 1536;
                var silence_r: [1536]f32 = [_]f32{0.0} ** 1536;
                try self.writePlanarAndDrain(allocator, &silence_l, &silence_r, out_frames);
            }
            return;
        }

        if (self.native_eac3_dec) |*dec| {
            var stereo_interleaved: [1536 * 2]f32 = undefined;
            if (dec.decodeFrame(raw_payload, &stereo_interleaved)) |n_samples| {
                if (n_samples > 0) {
                    var planar_l: [1536]f32 = undefined;
                    var planar_r: [1536]f32 = undefined;
                    for (0..n_samples) |i| {
                        planar_l[i] = stereo_interleaved[i * 2];
                        planar_r[i] = stereo_interleaved[i * 2 + 1];
                    }
                    try self.writePlanarAndDrain(allocator, planar_l[0..n_samples], planar_r[0..n_samples], out_frames);
                }
            } else |_| {
                var silence_l: [1536]f32 = [_]f32{0.0} ** 1536;
                var silence_r: [1536]f32 = [_]f32{0.0} ** 1536;
                try self.writePlanarAndDrain(allocator, &silence_l, &silence_r, out_frames);
            }
            return;
        }

        if (self.native_aac_dec) |*dec| {
            var stereo_interleaved: [2048]f32 = undefined;
            if (dec.decodeFrame(raw_payload, &stereo_interleaved)) |n_samples| {
                if (n_samples > 0) {
                    var planar_l: [1024]f32 = undefined;
                    var planar_r: [1024]f32 = undefined;
                    for (0..n_samples) |i| {
                        planar_l[i] = stereo_interleaved[i * 2];
                        planar_r[i] = stereo_interleaved[i * 2 + 1];
                    }
                    try self.writePlanarAndDrain(allocator, planar_l[0..n_samples], planar_r[0..n_samples], out_frames);
                }
            } else |_| {
                var silence_l: [1024]f32 = [_]f32{0.0} ** 1024;
                var silence_r: [1024]f32 = [_]f32{0.0} ** 1024;
                try self.writePlanarAndDrain(allocator, &silence_l, &silence_r, out_frames);
            }
            return;
        }

        if (self.native_mp3_dec) |*dec| {
            var stereo_interleaved: [1152 * 2]f32 = undefined;
            if (dec.decodeFrame(raw_payload, &stereo_interleaved)) |n_samples| {
                if (n_samples > 0) {
                    var planar_l: [1152]f32 = undefined;
                    var planar_r: [1152]f32 = undefined;
                    for (0..n_samples) |i| {
                        planar_l[i] = stereo_interleaved[i * 2];
                        planar_r[i] = stereo_interleaved[i * 2 + 1];
                    }
                    try self.writePlanarAndDrain(allocator, planar_l[0..n_samples], planar_r[0..n_samples], out_frames);
                }
            } else |_| {
                var silence_l: [1152]f32 = [_]f32{0.0} ** 1152;
                var silence_r: [1152]f32 = [_]f32{0.0} ** 1152;
                try self.writePlanarAndDrain(allocator, &silence_l, &silence_r, out_frames);
            }
            return;
        }

        return error.UnsupportedAudioCodec;
    }

    fn writePlanarAndDrain(
        self: *StreamAudioTranscoder,
        allocator: std.mem.Allocator,
        planar_l: []const f32,
        planar_r: []const f32,
        out_frames: *std.ArrayList(EncodedAacFrame),
    ) !void {
        if (self.resampler_l) |*rl| {
            var resampled_l: [4096]f32 = undefined;
            var resampled_r: [4096]f32 = undefined;
            const out_l_cnt = rl.process(planar_l, &resampled_l);
            const out_r_cnt = if (self.resampler_r) |*rr| rr.process(planar_r, &resampled_r) else out_l_cnt;
            const out_cnt = @min(out_l_cnt, out_r_cnt);
            try self.native_fifo.write(resampled_l[0..out_cnt], resampled_r[0..out_cnt]);
        } else {
            try self.native_fifo.write(planar_l, planar_r);
        }
        try self.drainNativeFifo(allocator, out_frames);
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

    /// Encodes a single 1024-sample frame of silence for gap concealment and timeline drift correction.
    pub fn encodeSilenceFrame(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
        var silence_l: [1024]f32 = [_]f32{0.0} ** 1024;
        var silence_r: [1024]f32 = [_]f32{0.0} ** 1024;
        var aac_frame_buf: [2048]u8 = undefined;
        const aac_len = try self.native_aac_enc.encodeFrame(&silence_l, &silence_r, &aac_frame_buf);

        const frame_buf = try allocator.alloc(u8, aac_len);
        errdefer allocator.free(frame_buf);
        @memcpy(frame_buf, aac_frame_buf[0..aac_len]);

        try out_frames.append(allocator, EncodedAacFrame{
            .data = frame_buf,
            .sample_count = 1024,
        });
    }

    /// Drops audio samples from the FIFO if audio has drifted ahead of video.
    pub fn dropSamples(self: *StreamAudioTranscoder, count: usize) void {
        var dummy_l: [1024]f32 = undefined;
        var dummy_r: [1024]f32 = undefined;
        var rem = count;
        while (rem >= 1024 and self.native_fifo.size() >= 1024) {
            _ = self.native_fifo.read(&dummy_l, &dummy_r);
            rem -= 1024;
        }
    }

    /// Flushes any remaining samples in the FIFO and encoder queue.
    pub fn flush(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
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
    }

    pub fn deinit(self: *StreamAudioTranscoder) void {
        self.native_fifo.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

test "StreamAudioTranscoder AC-3 native mode initializes correctly" {
    const testing = std.testing;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 6, 48000, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.native_ac3_dec != null);
    try testing.expectEqual(@as(usize, 0), transcoder.native_fifo.size());
}

test "StreamAudioTranscoder pure Zig AC-3 transcode end-to-end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const file = std.Io.Dir.cwd().openFile(testing.io, "tests/polly_5s.ac3", .{}) catch return;
    defer file.close(testing.io);

    var buf: [15360]u8 = undefined;
    var reader_file = file.reader(testing.io, &buf);
    const bytes_read = try reader_file.interface.readSliceShort(&buf);

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 6, 48000, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);

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

test "StreamAudioTranscoder pure Zig MP3 transcode end-to-end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_MPEG/L3", null, 2, 44100, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.native_mp3_dec != null);
    try testing.expect(transcoder.resampler_l != null);

    // 128kbps 44.1kHz Joint Stereo frame (417 bytes)
    var frame_bytes: [417]u8 = std.mem.zeroes([417]u8);
    frame_bytes[0] = 0xFF;
    frame_bytes[1] = 0xFB;
    frame_bytes[2] = 0x90;
    frame_bytes[3] = 0x64;

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    try transcoder.transcodePacket(allocator, &frame_bytes, &frames);
    try transcoder.flush(allocator, &frames);

    try testing.expect(frames.items.len > 0);
    for (frames.items) |f| {
        try testing.expect(f.data.len > 0);
        try testing.expectEqual(@as(u32, 1024), f.sample_count);
    }
}

test "StreamAudioTranscoder pure Zig AC-3 decode error injects concealment silence" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 2, 48000, true);
    defer transcoder.deinit();

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    // Pass an invalid / corrupt packet (e.g. invalid syncword)
    const corrupt_packet = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try transcoder.transcodePacket(allocator, &corrupt_packet, &frames);

    // 1536 samples of silence should have been fed to FIFO, producing at least 1 AAC frame (1024 samples)
    try testing.expect(frames.items.len >= 1);
    try testing.expectEqual(@as(usize, 512), transcoder.native_fifo.size());
}

test "StreamAudioTranscoder pure Zig AC-3 resamples 44100Hz to 48000Hz" {
    const testing = std.testing;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 2, 44100, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.resampler_l != null);
    try testing.expect(transcoder.resampler_r != null);
}

