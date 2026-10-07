const std = @import("std");
const decoder = @import("decoder.zig");
const Mp3Decoder = decoder.Mp3Decoder;

test "Mp3Decoder initialization and reset" {
    var dec = Mp3Decoder.init();
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    dec.reset();
}

test "Mp3Decoder decodeFrame valid MPEG-1 Layer III frame" {
    var dec = Mp3Decoder.init();
    var frame_bytes: [417]u8 = std.mem.zeroes([417]u8);
    // Standard 128kbps 44.1kHz Joint Stereo MPEG-1 Layer III header
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
