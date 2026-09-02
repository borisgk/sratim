const std = @import("std");
const mp3_dec = @import("mp3_dec.zig");
const transcoder_mod = @import("../../stream_audio_transcoder.zig");

test "Mp3Decoder test_mp3: standard frame decoding" {
    var dec = mp3_dec.Mp3Decoder.init();
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);

    // Synthetic 128kbps 44.1kHz Joint Stereo MPEG-1 Layer III frame (417 bytes)
    var frame_bytes: [417]u8 = std.mem.zeroes([417]u8);
    frame_bytes[0] = 0xFF;
    frame_bytes[1] = 0xFB;
    frame_bytes[2] = 0x90;
    frame_bytes[3] = 0x64;

    var out_pcm: [1152 * 2]f32 = undefined;
    const n_samples = try dec.decodeFrame(&frame_bytes, &out_pcm);
    try std.testing.expectEqual(@as(usize, 1152), n_samples);
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    try std.testing.expectEqual(@as(u16, 128), dec.bitrate_kbps);
}

test "Mp3Decoder test_mp3: 48kHz mono frame decoding" {
    var dec = mp3_dec.Mp3Decoder.init();

    // 64kbps 48kHz Mono MPEG-1 Layer III frame:
    // Header: 0xFF, 0xFB, 0x54, 0xC0
    // L = 144 * 64000 / 48000 = 192 bytes
    var frame_bytes: [192]u8 = std.mem.zeroes([192]u8);
    frame_bytes[0] = 0xFF;
    frame_bytes[1] = 0xFB;
    frame_bytes[2] = 0x54;
    frame_bytes[3] = 0xC0;

    var out_pcm: [1152 * 2]f32 = undefined;
    const n_samples = try dec.decodeFrame(&frame_bytes, &out_pcm);
    try std.testing.expectEqual(@as(usize, 1152), n_samples);
    try std.testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 1), dec.channels);
}
