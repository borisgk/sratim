const std = @import("std");
const sat = @import("stream_audio_transcoder.zig");
const StreamAudioTranscoder = sat.StreamAudioTranscoder;
const EncodedAacFrame = sat.EncodedAacFrame;
const dts_dec = sat.dts_dec;

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
