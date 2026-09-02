const std = @import("std");
const build_options = @import("build_options");
const dsp = @import("native/audio/dsp.zig");
const mdct = @import("native/audio/mdct.zig");
const ac3_dec = @import("native/audio/ac3_dec.zig");
const aac_dec = @import("native/audio/aac_dec.zig");
const bit_reader = @import("native/audio/ac3/bit_reader.zig");
const aac_enc = @import("native/audio/aac_enc.zig");
const track_parser = @import("native/mkv/track_parser.zig");
const types = @import("native/mkv/types.zig");
const block_reader = @import("native/mkv/block_reader.zig");

const stream_audio_transcoder = @import("stream_audio_transcoder.zig");
const EncodedAacFrame = stream_audio_transcoder.EncodedAacFrame;
const StreamAudioTranscoder = stream_audio_transcoder.StreamAudioTranscoder;

test "StreamAudioTranscoder decodes and encodes AAC frames" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const path: [:0]const u8 = "tests/test_sync.mkv";

    const tracks = track_parser.parseMkvTracks(allocator, io, path) catch return;
    defer {
        for (tracks) |*t| t.deinit(allocator);
        allocator.free(tracks);
    }

    var audio_track_opt: ?types.MkvTrackInfo = null;
    for (tracks) |t| {
        if (t.track_type == .Audio) {
            audio_track_opt = t;
            break;
        }
    }
    try testing.expect(audio_track_opt != null);
    const audio_track = audio_track_opt.?;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AAC", audio_track.codec_private, audio_track.channels, audio_track.sample_rate, true);
    defer transcoder.deinit();

    const demux_file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    var current_file_pos: u64 = 0;
    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            try transcoder.transcodePacket(allocator, raw_pkt_buf.items, &frames);
            if (frames.items.len >= 5) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len >= 5);

    // Verify all generated frames decode cleanly with native AacDecoder
    var dec = aac_dec.AacDecoder.init();
    dec.sample_rate = 48000;
    dec.channels = 2;
    var dec_pcm: [2048]f32 = undefined;

    for (frames.items) |f| {
        try testing.expect(f.data.len > 0);
        const n_samples = try dec.decodeFrame(f.data, &dec_pcm);
        try testing.expectEqual(@as(usize, 1024), n_samples);
    }
}

test "StreamAudioTranscoder decodes 6-channel EAC3 from Reacher.mkv and encodes to stereo AAC" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const test_file: [:0]const u8 = "tests/Reacher.mkv";

    const tracks = track_parser.parseMkvTracks(allocator, io, test_file) catch return;
    defer {
        for (tracks) |*t| t.deinit(allocator);
        allocator.free(tracks);
    }

    var audio_track_opt: ?types.MkvTrackInfo = null;
    for (tracks) |t| {
        if (t.track_type == .Audio) {
            audio_track_opt = t;
            break;
        }
    }
    try testing.expect(audio_track_opt != null);
    const audio_track = audio_track_opt.?;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_EAC3", audio_track.codec_private, audio_track.channels, audio_track.sample_rate, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.native_eac3_dec != null);

    const demux_file = try std.Io.Dir.cwd().openFile(io, test_file, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, test_file, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    var current_file_pos: u64 = 0;
    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            try transcoder.transcodePacket(allocator, raw_pkt_buf.items, &frames);
            if (frames.items.len >= 5) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len >= 5);

    var dec = aac_dec.AacDecoder.init();
    dec.sample_rate = 48000;
    dec.channels = 2;
    var dec_pcm: [2048]f32 = undefined;

    for (frames.items) |f| {
        try testing.expect(f.data.len > 0);
        const n_samples = try dec.decodeFrame(f.data, &dec_pcm);
        try testing.expectEqual(@as(usize, 1024), n_samples);
    }
}

test "StreamAudioTranscoder decodes 6-channel AAC from Tuner.mkv and downmixes/encodes to stereo AAC" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const test_file: [:0]const u8 = "tests/Tuner.mkv";

    const tracks = track_parser.parseMkvTracks(allocator, io, test_file) catch return;
    defer {
        for (tracks) |*t| t.deinit(allocator);
        allocator.free(tracks);
    }

    var audio_track_opt: ?types.MkvTrackInfo = null;
    for (tracks) |t| {
        if (t.track_type == .Audio) {
            audio_track_opt = t;
            break;
        }
    }
    try testing.expect(audio_track_opt != null);
    const audio_track = audio_track_opt.?;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AAC", audio_track.codec_private, audio_track.channels, audio_track.sample_rate, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.native_aac_dec != null);

    const demux_file = try std.Io.Dir.cwd().openFile(io, test_file, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, test_file, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    var current_file_pos: u64 = 0;
    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            try transcoder.transcodePacket(allocator, raw_pkt_buf.items, &frames);
            if (frames.items.len >= 5) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len >= 5);

    var dec = aac_dec.AacDecoder.init();
    dec.sample_rate = 48000;
    dec.channels = 2;
    var dec_pcm: [2048]f32 = undefined;

    for (frames.items) |f| {
        try testing.expect(f.data.len > 0);
        const n_samples = try dec.decodeFrame(f.data, &dec_pcm);
        try testing.expectEqual(@as(usize, 1024), n_samples);
    }
}

test "StreamAudioTranscoder decodes 6-channel AC3 from Polly.mkv and encodes to stereo AAC" {
    if (!build_options.test_audio) return;
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;
    const test_file: [:0]const u8 = "tests/Polly.mkv";

    const tracks = track_parser.parseMkvTracks(allocator, io, test_file) catch return;
    defer {
        for (tracks) |*t| t.deinit(allocator);
        allocator.free(tracks);
    }

    var audio_track_opt: ?types.MkvTrackInfo = null;
    for (tracks) |t| {
        if (t.track_type == .Audio) {
            audio_track_opt = t;
            break;
        }
    }
    try testing.expect(audio_track_opt != null);
    const audio_track = audio_track_opt.?;

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AC3", audio_track.codec_private, audio_track.channels, audio_track.sample_rate, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.native_ac3_dec != null);

    const demux_file = try std.Io.Dir.cwd().openFile(io, test_file, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, test_file, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    var current_file_pos: u64 = 0;
    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            try transcoder.transcodePacket(allocator, raw_pkt_buf.items, &frames);
            if (frames.items.len >= 5) break;
        }
    }

    try transcoder.flush(allocator, &frames);
    try testing.expect(frames.items.len >= 5);

    var dec = aac_dec.AacDecoder.init();
    dec.sample_rate = 48000;
    dec.channels = 2;
    var dec_pcm: [2048]f32 = undefined;

    for (frames.items) |f| {
        try testing.expect(f.data.len > 0);
        const n_samples = try dec.decodeFrame(f.data, &dec_pcm);
        try testing.expectEqual(@as(usize, 1024), n_samples);
    }
}

test "Inspect native AAC roundtrip decoded PCM levels" {
    if (!build_options.test_audio) return;
    const testing = std.testing;
    var encoder = aac_enc.AacEncoder.init(48000, 192000);
    var decoder = aac_dec.AacDecoder.init();
    decoder.sample_rate = 48000;
    decoder.channels = 2;

    const INPUT_AMP: f32 = 0.5;
    var max_out_pcm: f32 = 0.0;
    var num_decoded_frames: usize = 0;

    var decoded_samples = std.ArrayList(f32).empty;
    defer decoded_samples.deinit(testing.allocator);

    for (0..10) |f| {
        var in_l: [1024]f32 = undefined;
        var in_r: [1024]f32 = undefined;
        for (0..1024) |i| {
            const sample_idx = f * 1024 + i;
            const t = @as(f32, @floatFromInt(sample_idx)) / 48000.0;
            in_l[i] = INPUT_AMP * @sin(2.0 * std.math.pi * 440.0 * t);
            in_r[i] = INPUT_AMP * @sin(2.0 * std.math.pi * 440.0 * t);
        }

        var aac_buf: [2048]u8 = undefined;
        const aac_len = try encoder.encodeFrame(&in_l, &in_r, &aac_buf);

        var dec_buf: [2048]f32 = undefined;
        if (decoder.decodeFrame(aac_buf[0..aac_len], &dec_buf)) |nb| {
            num_decoded_frames += 1;
            for (dec_buf[0 .. nb * 2]) |s| {
                max_out_pcm = @max(max_out_pcm, @abs(s));
                try decoded_samples.append(testing.allocator, s);
            }
        } else |_| {}
    }

    var dot: f64 = 0;
    var norm_in: f64 = 0;
    var norm_out: f64 = 0;
    if (decoded_samples.items.len >= 4096) {
        const DELAY = 1024 * 2;
        for (1024..decoded_samples.items.len / 2 - 1024) |idx| {
            const in_t = @as(f32, @floatFromInt(idx)) / 48000.0;
            const expected = INPUT_AMP * @sin(2.0 * std.math.pi * 440.0 * in_t);
            const actual = decoded_samples.items[idx * 2 + DELAY];
            dot += @as(f64, expected) * @as(f64, actual);
            norm_in += @as(f64, expected) * @as(f64, expected);
            norm_out += @as(f64, actual) * @as(f64, actual);
        }
    }
    const corr = if (norm_in > 0 and norm_out > 0) dot / (@sqrt(norm_in) * @sqrt(norm_out)) else 0.0;
    std.debug.print("\nNative AAC Encoder -> Native AAC Decoder roundtrip correlation: {d:.4}, max_out={d:.4}\n", .{ corr, max_out_pcm });

    try testing.expect(num_decoded_frames >= 5);
    try testing.expect(max_out_pcm > INPUT_AMP * 0.7);
    try testing.expect(max_out_pcm < INPUT_AMP * 1.5);
    try testing.expect(corr > 0.85);
}

test {
    std.testing.refAllDecls(aac_enc);
    std.testing.refAllDecls(ac3_dec);
}

