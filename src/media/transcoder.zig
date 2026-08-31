const std = @import("std");
const build_options = @import("build_options");
pub const c = @import("../core/c.zig").c;
pub const dsp = @import("native/audio/dsp.zig");
pub const mdct = @import("native/audio/mdct.zig");
pub const ac3_dec = @import("native/audio/ac3_dec.zig");
pub const aac_dec = @import("native/audio/aac_dec.zig");
pub const bit_reader = @import("native/audio/ac3/bit_reader.zig");
pub const aac_enc = @import("native/audio/aac_enc.zig");

pub const ffmpeg_transcoder = @import("ffmpeg_transcoder.zig");
pub const AudioTranscoder = ffmpeg_transcoder.AudioTranscoder;

pub const stream_audio_transcoder = @import("stream_audio_transcoder.zig");
pub const EncodedAacFrame = stream_audio_transcoder.EncodedAacFrame;
pub const StreamAudioTranscoder = stream_audio_transcoder.StreamAudioTranscoder;

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

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.ffmpeg_state == null);
    try testing.expect(transcoder.native_eac3_dec != null);

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
    if (extradata_slice) |ed| {
        std.debug.print("\n=== TUNER EXTRADATA len={d}: ", .{ed.len});
        for (ed) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("===\n", .{});
    }

    var transcoder = try StreamAudioTranscoder.initFromCodec("A_AAC", extradata_slice, 6, 48000, true);
    defer transcoder.deinit();

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.ffmpeg_state == null);
    try testing.expect(transcoder.native_aac_dec != null);

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    var frames = std.ArrayList(EncodedAacFrame).empty;
    defer {
        for (frames.items) |f| allocator.free(f.data);
        frames.deinit(allocator);
    }

    var native_dec = aac_dec.AacDecoder.init();
    native_dec.sample_rate = 48000;
    native_dec.channels = 6;

    var pcm_samples = std.ArrayList(f32).empty;
    defer pcm_samples.deinit(allocator);
    var pcm_6ch = std.ArrayList(f32).empty;
    defer pcm_6ch.deinit(allocator);

    var audio_pkt_idx: usize = 0;
    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == audio_stream_idx) {
            defer audio_pkt_idx += 1;
            const raw_data: []const u8 = pkt.*.data[0..@intCast(pkt.*.size)];
            try transcoder.transcodePacket(allocator, raw_data, &frames);

            var stereo_buf: [2048]f32 = undefined;
            if (native_dec.decodeFrame(raw_data, &stereo_buf)) |n_samples| {
                if (n_samples > 0) {
                    try pcm_samples.appendSlice(allocator, stereo_buf[0 .. n_samples * 2]);
                    for (0..1024) |s| {
                        for (0..6) |ch| {
                            try pcm_6ch.append(allocator, native_dec.last_ch_pcm[ch][s] * (1.0 / 65536.0));
                        }
                    }
                }
            } else |err| {
                std.debug.print("  [FIRST TUNER ERR] pkt_idx={} len={} err={}\n", .{ audio_pkt_idx, raw_data.len, err });
                break;
            }

            if (frames.items.len >= 200) break;
        }
    }

    // Write tmp/native_out.wav via C stdio
    if (std.c.fopen("tmp/native_out.wav", "wb")) |f| {
        defer _ = std.c.fclose(f);
        const data_size: u32 = @intCast(pcm_samples.items.len * 2);
        const file_size = 36 + data_size;
        _ = std.c.fwrite("RIFF", 1, 4, f);
        _ = std.c.fwrite(@ptrCast(&file_size), 4, 1, f);
        _ = std.c.fwrite("WAVEfmt ", 1, 8, f);
        const sub1: u32 = 16;
        const fmt_tag: u16 = 1;
        const chs: u16 = 2;
        const srate: u32 = 48000;
        const brate: u32 = 48000 * 4;
        const balign: u16 = 4;
        const bps: u16 = 16;
        _ = std.c.fwrite(@ptrCast(&sub1), 4, 1, f);
        _ = std.c.fwrite(@ptrCast(&fmt_tag), 2, 1, f);
        _ = std.c.fwrite(@ptrCast(&chs), 2, 1, f);
        _ = std.c.fwrite(@ptrCast(&srate), 4, 1, f);
        _ = std.c.fwrite(@ptrCast(&brate), 4, 1, f);
        _ = std.c.fwrite(@ptrCast(&balign), 2, 1, f);
        _ = std.c.fwrite(@ptrCast(&bps), 2, 1, f);
        _ = std.c.fwrite("data", 1, 4, f);
        _ = std.c.fwrite(@ptrCast(&data_size), 4, 1, f);
        for (pcm_samples.items) |s| {
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const i16_val: i16 = @intFromFloat(clamped * 32767.0);
            _ = std.c.fwrite(@ptrCast(&i16_val), 2, 1, f);
        }
        std.debug.print("\nWrote {} samples to tmp/native_out.wav\n", .{pcm_samples.items.len / 2});
    }

    // Write tmp/native_6ch.wav via C stdio
    if (std.c.fopen("tmp/native_6ch.wav", "wb")) |f| {
        defer _ = std.c.fclose(f);
        const data_size: u32 = @intCast(pcm_6ch.items.len * 2);
        const file_size = 36 + data_size;
        _ = std.c.fwrite("RIFF", 1, 4, f);
        _ = std.c.fwrite(@ptrCast(&file_size), 4, 1, f);
        _ = std.c.fwrite("WAVEfmt ", 1, 8, f);
        const sub1: u32 = 16;
        const fmt_tag: u16 = 1;
        const chs: u16 = 6;
        const srate: u32 = 48000;
        const brate: u32 = 48000 * 6 * 2;
        const balign: u16 = 12;
        const bps: u16 = 16;
        _ = std.c.fwrite(@ptrCast(&sub1), 4, 1, f);
        _ = std.c.fwrite(@ptrCast(&fmt_tag), 2, 1, f);
        _ = std.c.fwrite(@ptrCast(&chs), 2, 1, f);
        _ = std.c.fwrite(@ptrCast(&srate), 4, 1, f);
        _ = std.c.fwrite(@ptrCast(&brate), 4, 1, f);
        _ = std.c.fwrite(@ptrCast(&balign), 2, 1, f);
        _ = std.c.fwrite(@ptrCast(&bps), 2, 1, f);
        _ = std.c.fwrite("data", 1, 4, f);
        _ = std.c.fwrite(@ptrCast(&data_size), 4, 1, f);
        for (pcm_6ch.items) |s| {
            const clamped = std.math.clamp(s, -1.0, 1.0);
            const i16_val: i16 = @intFromFloat(clamped * 32767.0);
            _ = std.c.fwrite(@ptrCast(&i16_val), 2, 1, f);
        }
        std.debug.print("Wrote {} frames to tmp/native_6ch.wav\n", .{pcm_6ch.items.len / 6});
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
    if (!build_options.test_audio) return;
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

    try testing.expect(transcoder.is_pure_native);
    try testing.expect(transcoder.ffmpeg_state == null);
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
    if (!build_options.test_audio) return;
    const testing = std.testing;
    var encoder = aac_enc.AacEncoder.init(48000, 192000);

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

        const adts = aac_enc.AacEncoder.buildAdtsHeader(aac_len, 48000, 2);
        var full_buf: [4096]u8 = undefined;
        @memcpy(full_buf[0..7], &adts);
        @memcpy(full_buf[7 .. 7 + aac_len], aac_buf[0..aac_len]);

        dec_pkt.*.data = @ptrCast(&full_buf);
        dec_pkt.*.size = @intCast(7 + aac_len);
        _ = c.avcodec_send_packet(dec_ctx, dec_pkt);

        while (c.avcodec_receive_frame(dec_ctx, dec_frame) >= 0) {
            num_decoded_frames += 1;
            const nb: usize = @intCast(dec_frame.*.nb_samples);
            const data = @as([*c][*c]f32, @ptrCast(&dec_frame.*.data));
            for (data[0][0..nb]) |s| {
                max_out_pcm = @max(max_out_pcm, @abs(s));
                try decoded_samples.append(testing.allocator, s);
            }
        }
    }

    // Measure correlation on steady-state frames (skip first 1024 samples of decoder priming)
    var dot: f64 = 0;
    var norm_in: f64 = 0;
    var norm_out: f64 = 0;
    if (decoded_samples.items.len >= 4096) {
        // AAC decoder delay is exactly 1024 samples
        const DELAY = 1024;
        for (1024..decoded_samples.items.len - 1024) |idx| {
            const in_t = @as(f32, @floatFromInt(idx)) / 48000.0;
            const expected = INPUT_AMP * @sin(2.0 * std.math.pi * 440.0 * in_t);
            const actual = decoded_samples.items[idx + DELAY];
            dot += @as(f64, expected) * @as(f64, actual);
            norm_in += @as(f64, expected) * @as(f64, expected);
            norm_out += @as(f64, actual) * @as(f64, actual);
        }
    }
    const corr = if (norm_in > 0 and norm_out > 0) dot / (@sqrt(norm_in) * @sqrt(norm_out)) else 0.0;
    std.debug.print("\nNative AAC -> libavcodec decoded correlation: {d:.4}, max_out={d:.4}\n", .{ corr, max_out_pcm });

    // Decoded amplitude should be close to input (roundtrip ratio ~1.0)
    try testing.expect(num_decoded_frames >= 5);
    try testing.expect(max_out_pcm > INPUT_AMP * 0.7);
    try testing.expect(max_out_pcm < INPUT_AMP * 1.5);
    try testing.expect(corr > 0.85);
}

test {
    std.testing.refAllDecls(aac_enc);
    std.testing.refAllDecls(ac3_dec);
}
