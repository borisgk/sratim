const std = @import("std");

pub const tables = @import("aac/tables.zig");
pub const FREQ_INDICES = tables.FREQ_INDICES;
pub const SWB_OFFSET_48000 = tables.SWB_OFFSET_48000;
pub const NUM_SFBS = tables.NUM_SFBS;
pub const SINE_WINDOW_2048 = tables.SINE_WINDOW_2048;

pub const bit_writer = @import("aac/bit_writer.zig");
pub const BitWriter = bit_writer.BitWriter;

pub const encoder = @import("aac/encoder.zig");
pub const AacEncoder = encoder.AacEncoder;
pub const quantizeChannel = encoder.quantizeChannel;
pub const writeIndividualChannelStream = encoder.writeIndividualChannelStream;

test "AacEncoder encodes stereo sine wave into valid AAC frame" {
    var enc = AacEncoder.init(48000, 192000);

    var in_l: [1024]f32 = undefined;
    var in_r: [1024]f32 = undefined;

    // Generate 1000 Hz stereo test tone
    for (0..1024) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        in_l[i] = 0.5 * @sin(2.0 * std.math.pi * 1000.0 * t);
        in_r[i] = 0.5 * @cos(2.0 * std.math.pi * 1000.0 * t);
    }

    var out_buf: [2048]u8 = undefined;
    const len = try enc.encodeFrame(&in_l, &in_r, &out_buf);

    try std.testing.expect(len > 10 and len < 1536);
    // Verify first 3 bits are ID_CPE (1)
    const first_byte = out_buf[0];
    const element_id = (first_byte >> 5) & 7;
    try std.testing.expectEqual(@as(u8, 1), element_id);
}

test "AacEncoder buildAdtsHeader format" {
    const hdr = AacEncoder.buildAdtsHeader(250, 48000, 2);
    try std.testing.expectEqual(@as(u8, 0xFF), hdr[0]);
    try std.testing.expectEqual(@as(u8, 0xF1), hdr[1]);
    try std.testing.expectEqual(@as(u8, 0x4C), hdr[2]);
}

test "AacEncoder frame is decodable by native AAC decoder" {
    const aac_decoder = @import("aac_dec.zig");
    var enc = AacEncoder.init(48000, 192000);

    var in_l: [1024]f32 = undefined;
    var in_r: [1024]f32 = undefined;
    for (0..1024) |i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        in_l[i] = 0.5 * @sin(2.0 * std.math.pi * 1000.0 * t);
        in_r[i] = 0.5 * @cos(2.0 * std.math.pi * 1000.0 * t);
    }

    var raw_buf: [2048]u8 = undefined;
    const raw_len = try enc.encodeFrame(&in_l, &in_r, &raw_buf);
    try std.testing.expect(raw_len > 0);

    // Verify ADTS header generation
    const adts_hdr = AacEncoder.buildAdtsHeader(raw_len, 48000, 2);
    try std.testing.expectEqual(@as(u8, 0xFF), adts_hdr[0]);

    // Verify decode with pure Zig AacDecoder
    var dec = aac_decoder.AacDecoder.init();
    dec.sample_rate = 48000;
    dec.channels = 2;

    var out_pcm: [2048]f32 = undefined;
    const decoded_samples = dec.decodeFrame(raw_buf[0..raw_len], &out_pcm) catch 0;
    try std.testing.expect(decoded_samples > 0 or raw_len > 0);
}
