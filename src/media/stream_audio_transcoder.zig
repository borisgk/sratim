const std = @import("std");
pub const ac3_dec = @import("native/audio/ac3_dec.zig");
pub const eac3_dec = @import("native/audio/eac3_dec.zig");
pub const aac_dec = @import("native/audio/aac_dec.zig");
pub const aac_enc = @import("native/audio/aac_enc.zig");
pub const audio_fifo = @import("native/audio/fifo.zig");

pub const mp3_dec = @import("native/audio/mp3_dec.zig");
pub const dts_dec = @import("native/audio/dts_dec.zig");
pub const dsp = @import("native/audio/dsp.zig");

pub const EncodedAacFrame = struct {
    data: []u8,
    sample_count: u32 = 1024,
};

/// Standalone pure Zig audio transcoder that converts compressed audio packets (AC-3, E-AC-3, MP3, DTS, multichannel AAC)
/// into standardized 48kHz Stereo AAC frames for native fMP4 container muxing.
/// Operates 100% in pure Zig with zero FFmpeg dependencies.
pub const StreamAudioTranscoder = struct {
    target_channels: u8 = 2,
    is_pure_native: bool = true,
    native_fifo: audio_fifo.AudioFifo,
    native_aac_enc: aac_enc.AacEncoder,
    native_ac3_dec: ?ac3_dec.Ac3Decoder = null,
    native_eac3_dec: ?eac3_dec.Eac3Decoder = null,
    native_aac_dec: ?aac_dec.AacDecoder = null,
    native_mp3_dec: ?mp3_dec.Mp3Decoder = null,
    native_dts_dec: ?dts_dec.DtsDecoder = null,
    resampler_l: ?dsp.HermiteResampler = null,
    resampler_r: ?dsp.HermiteResampler = null,

    // Comptime codec name tuples — single source of truth for codec matching.
    const ac3_codecs = .{ "A_AC3", "ac-3", "sac3" };
    const eac3_codecs = .{ "A_EAC3", "ec-3" };
    const aac_codecs = .{ "A_AAC", "mp4a" };
    const mp3_codecs = .{ "A_MPEG/L3", "A_MPEG/L2", "A_MPEG/L1", ".mp3", "mp3", "mp3 " };
    const dts_codecs = .{ "A_DTS", "dts ", "dtsc", "dtsh", "dts-hd" };

    /// Comptime-unrolled string match against a tuple of known codec names.
    fn matchesAny(codec_name: []const u8, comptime names: anytype) bool {
        inline for (names) |name| {
            if (std.mem.eql(u8, codec_name, name)) return true;
        }
        return false;
    }

    fn matchesDts(codec_name: []const u8) bool {
        return matchesAny(codec_name, dts_codecs) or std.mem.startsWith(u8, codec_name, "A_DTS/");
    }

    pub fn isNativeSupportedCodec(codec_name: []const u8) bool {
        return matchesAny(codec_name, ac3_codecs) or
            matchesAny(codec_name, eac3_codecs) or
            matchesAny(codec_name, aac_codecs) or
            matchesAny(codec_name, mp3_codecs) or
            matchesDts(codec_name);
    }

    pub fn initFromCodec(
        codec_name: []const u8,
        codec_private: ?[]const u8,
        channels: u16,
        sample_rate: u32,
        use_native_encoder: bool,
    ) !*StreamAudioTranscoder {
        _ = use_native_encoder;
        const allocator = std.heap.c_allocator;
        const is_ac3 = matchesAny(codec_name, ac3_codecs);
        const is_eac3 = matchesAny(codec_name, eac3_codecs);
        const is_aac = matchesAny(codec_name, aac_codecs);
        const is_mp3 = matchesAny(codec_name, mp3_codecs);
        const is_dts = matchesDts(codec_name);

        if (!is_ac3 and !is_eac3 and !is_aac and !is_mp3 and !is_dts) {
            return error.UnsupportedAudioCodec;
        }

        const self = try allocator.create(StreamAudioTranscoder);
        errdefer allocator.destroy(self);

        var aac_dec_inst: ?aac_dec.AacDecoder = null;
        var effective_sample_rate = sample_rate;

        if (is_aac) {
            var d = aac_dec.AacDecoder.init();
            if (codec_private) |cp| {
                if (d.configureFromAudioSpecificConfig(cp)) {
                    effective_sample_rate = d.sample_rate;
                } else |_| {
                    d.setSampleRate(sample_rate);
                    d.channels = channels;
                }
            } else {
                d.setSampleRate(sample_rate);
                d.channels = channels;
            }
            aac_dec_inst = d;
        }

        const needs_resample = (effective_sample_rate != 48000 and effective_sample_rate > 0);

        self.* = .{
            .is_pure_native = true,
            .native_fifo = audio_fifo.AudioFifo.init(allocator),
            .native_aac_enc = aac_enc.AacEncoder.init(48000, 192000),
            .native_ac3_dec = if (is_ac3) ac3_dec.Ac3Decoder.init() else null,
            .native_eac3_dec = if (is_eac3) eac3_dec.Eac3Decoder.init() else null,
            .native_aac_dec = aac_dec_inst,
            .native_mp3_dec = if (is_mp3) mp3_dec.Mp3Decoder.init() else null,
            .native_dts_dec = if (is_dts) dts_dec.DtsDecoder.init() else null,
            .resampler_l = if (needs_resample) dsp.HermiteResampler.init(effective_sample_rate, 48000) else null,
            .resampler_r = if (needs_resample) dsp.HermiteResampler.init(effective_sample_rate, 48000) else null,
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
                try self.injectConcealmentSilence(allocator, 1536, out_frames);
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
                try self.injectConcealmentSilence(allocator, 1536, out_frames);
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
                try self.injectConcealmentSilence(allocator, 1024, out_frames);
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
                try self.injectConcealmentSilence(allocator, 1152, out_frames);
            }
            return;
        }

        if (self.native_dts_dec) |*dec| {
            var stereo_interleaved: [2048 * 2]f32 = undefined;
            if (dec.decodeFrame(raw_payload, &stereo_interleaved)) |n_samples| {
                if (n_samples > 0) {
                    var planar_l: [2048]f32 = undefined;
                    var planar_r: [2048]f32 = undefined;
                    for (0..n_samples) |i| {
                        planar_l[i] = stereo_interleaved[i * 2];
                        planar_r[i] = stereo_interleaved[i * 2 + 1];
                    }
                    try self.writePlanarAndDrain(allocator, planar_l[0..n_samples], planar_r[0..n_samples], out_frames);
                }
            } else |_| {
                try self.injectConcealmentSilence(allocator, 1024, out_frames);
            }
            return;
        }

        return error.UnsupportedAudioCodec;
    }

    /// Emits smooth concealment silence (ramped down from previous audio sample if needed)
    /// to preserve audio clock timing on packet decode error without clicking.
    fn injectConcealmentSilence(
        self: *StreamAudioTranscoder,
        allocator: std.mem.Allocator,
        comptime count: usize,
        out_frames: *std.ArrayList(EncodedAacFrame),
    ) !void {
        var silence_l: [count]f32 = [_]f32{0.0} ** count;
        var silence_r: [count]f32 = [_]f32{0.0} ** count;

        // If FIFO has preceding samples, smoothly ramp down over up to 32 samples to prevent clicks
        if (self.native_fifo.size() > 0) {
            const last_l = self.native_fifo.left.items[self.native_fifo.left.items.len - 1];
            const last_r = self.native_fifo.right.items[self.native_fifo.right.items.len - 1];
            if (@abs(last_l) > 1e-4 or @abs(last_r) > 1e-4) {
                const ramp_len = @min(count, 32);
                for (0..ramp_len) |k| {
                    const factor = @as(f32, @floatFromInt(ramp_len - 1 - k)) / @as(f32, @floatFromInt(ramp_len));
                    silence_l[k] = last_l * factor;
                    silence_r[k] = last_r * factor;
                }
            }
        }
        try self.writePlanarAndDrain(allocator, &silence_l, &silence_r, out_frames);
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

    /// Pushes silence samples into the FIFO and drains ready AAC frames.
    /// Preserves FIFO ordering and smooths MDCT overlap transitions without phase jumps or clicks.
    pub fn encodeSilenceSamples(
        self: *StreamAudioTranscoder,
        allocator: std.mem.Allocator,
        sample_count: usize,
        out_frames: *std.ArrayList(EncodedAacFrame),
    ) !void {
        const silence_zeros: [1024]f32 = [_]f32{0.0} ** 1024;
        var rem = sample_count;
        while (rem > 0) {
            const chunk = @min(rem, 1024);
            try self.native_fifo.write(silence_zeros[0..chunk], silence_zeros[0..chunk]);
            rem -= chunk;
        }
        try self.drainNativeFifo(allocator, out_frames);
    }

    /// Encodes silence corresponding to 1024 samples for gap concealment and timeline drift correction.
    /// Queues silence through the FIFO to preserve chronological ordering of pending decoder samples.
    pub fn encodeSilenceFrame(self: *StreamAudioTranscoder, allocator: std.mem.Allocator, out_frames: *std.ArrayList(EncodedAacFrame)) !void {
        try self.encodeSilenceSamples(allocator, 1024, out_frames);
    }

    /// Drops audio samples from the FIFO if audio has drifted ahead of video.
    /// Applies a smooth cross-fade to prevent step discontinuities (clicks/pops).
    pub fn dropSamples(self: *StreamAudioTranscoder, count: usize) void {
        const avail = self.native_fifo.size();
        if (avail <= count) {
            self.native_fifo.clear();
            return;
        }
        const fade_len: usize = 32;
        if (avail >= count + fade_len) {
            // Apply quick linear ramp out on pre-drop samples
            const left_slice = self.native_fifo.left.items[self.native_fifo.read_pos..];
            const right_slice = self.native_fifo.right.items[self.native_fifo.read_pos..];
            for (0..fade_len) |i| {
                const w = @as(f32, @floatFromInt(fade_len - 1 - i)) / @as(f32, @floatFromInt(fade_len));
                left_slice[i] *= w;
                right_slice[i] *= w;
            }
            self.native_fifo.read_pos += count;
            // Ramp in the post-drop samples
            const new_l = self.native_fifo.left.items[self.native_fifo.read_pos..];
            const new_r = self.native_fifo.right.items[self.native_fifo.read_pos..];
            for (0..fade_len) |i| {
                const w = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(fade_len));
                new_l[i] *= w;
                new_r[i] *= w;
            }
        } else {
            self.native_fifo.read_pos += count;
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

test "StreamAudioTranscoder encodeSilenceFrame queues through FIFO preserving sample order" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 2, 48000, true);
    defer transcoder.deinit();

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    // Pre-populate FIFO with 512 non-zero audio samples (as left behind by an AC-3 packet)
    var tone_l: [512]f32 = undefined;
    var tone_r: [512]f32 = undefined;
    for (0..512) |i| {
        tone_l[i] = 0.25;
        tone_r[i] = 0.25;
    }
    try transcoder.native_fifo.write(&tone_l, &tone_r);
    try testing.expectEqual(@as(usize, 512), transcoder.native_fifo.size());

    // Encode a 1024-sample silence frame
    try transcoder.encodeSilenceFrame(allocator, &frames);

    // Should have drained exactly 1 AAC frame (1024 samples = 512 tone + 512 silence)
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    // 512 samples of silence should remain in FIFO for smooth fade into the next packet
    try testing.expectEqual(@as(usize, 512), transcoder.native_fifo.size());
}

test "StreamAudioTranscoder encodeSilenceSamples accurately handles fractional sample counts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", null, 2, 48000, true);
    defer transcoder.deinit();

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    // Insert 2500 samples of silence (e.g. 52ms gap)
    try transcoder.encodeSilenceSamples(allocator, 2500, &frames);

    // 2500 samples should produce 2 full AAC frames (2048 samples) and leave 452 samples in FIFO
    try testing.expectEqual(@as(usize, 2), frames.items.len);
    try testing.expectEqual(@as(usize, 452), transcoder.native_fifo.size());
}

test "StreamAudioTranscoder DTS native mode initializes correctly" {
    const testing = std.testing;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_DTS", null, 6, 48000, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.native_dts_dec != null);
    try testing.expectEqual(@as(usize, 0), transcoder.native_fifo.size());
}

test "StreamAudioTranscoder pure Zig DTS transcode end-to-end" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const file = std.Io.Dir.cwd().openFile(testing.io, "tests/test_dts_5s.dts", .{}) catch return;
    defer file.close(testing.io);

    var buf: [16384]u8 = undefined;
    var reader_file = file.reader(testing.io, &buf);
    const bytes_read = try reader_file.interface.readSliceShort(&buf);
    try testing.expect(bytes_read > 2000);

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_DTS", null, 6, 48000, true);
    defer transcoder.deinit();

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    // Find first DTS frame
    const sync = dts_dec.findSync(buf[0..bytes_read]) orelse return error.SyncNotFound;
    var cur_off = sync.offset;
    for (0..2) |_| {
        var sub_r = dts_dec.BitReader.init(buf[cur_off..bytes_read]);
        const sub_hdr = try dts_dec.parseHeader(&sub_r);
        try transcoder.transcodePacket(allocator, buf[cur_off .. cur_off + sub_hdr.frame_size], &frames);
        cur_off += sub_hdr.frame_size;
    }

    // 2 x 512 DTS samples fed into FIFO should have encoded 1 AAC frame of 1024 samples
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    try testing.expect(frames.items[0].data.len > 0);
    try testing.expectEqual(@as(usize, 0), transcoder.native_fifo.size());
}


