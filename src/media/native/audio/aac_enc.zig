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

test "AacEncoder frame is decodable by libavcodec AAC decoder" {
    const c = @import("../../transcoder.zig").c;
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

    // Prefix with ADTS header
    const adts_hdr = AacEncoder.buildAdtsHeader(raw_len, 48000, 2);
    var packet_buf: [2048]u8 = undefined;
    @memcpy(packet_buf[0..7], &adts_hdr);
    @memcpy(packet_buf[7 .. 7 + raw_len], raw_buf[0..raw_len]);
    const total_len = raw_len + 7;

    const dec = c.avcodec_find_decoder(c.AV_CODEC_ID_AAC) orelse return error.DecoderNotFound;
    var dec_ctx = c.avcodec_alloc_context3(dec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&dec_ctx);

    dec_ctx.*.sample_rate = 48000;
    c.av_channel_layout_default(&dec_ctx.*.ch_layout, 2);

    if (c.avcodec_open2(dec_ctx, dec, null) < 0) return error.DecoderOpenFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(@ptrCast(&pkt));

    pkt.*.data = @ptrCast(&packet_buf);
    pkt.*.size = @intCast(total_len);

    const send_ret = c.avcodec_send_packet(dec_ctx, pkt);
    if (send_ret < 0) {
        var err_buf: [128]u8 = undefined;
        _ = c.av_strerror(send_ret, &err_buf, err_buf.len);
        std.debug.print("avcodec_send_packet failed: {s}\n", .{err_buf});
        return error.SendPacketFailed;
    }

    // Encode and send second frame to drain decoder delay
    const raw_len2 = try enc.encodeFrame(&in_l, &in_r, &raw_buf);
    const adts_hdr2 = AacEncoder.buildAdtsHeader(raw_len2, 48000, 2);
    @memcpy(packet_buf[0..7], &adts_hdr2);
    @memcpy(packet_buf[7 .. 7 + raw_len2], raw_buf[0..raw_len2]);
    pkt.*.data = @ptrCast(&packet_buf);
    pkt.*.size = @intCast(raw_len2 + 7);
    _ = c.avcodec_send_packet(dec_ctx, pkt);

    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(@ptrCast(&frame));

    var max_amp: f32 = 0.0;
    while (c.avcodec_receive_frame(dec_ctx, frame) >= 0) {
        const nb: usize = @intCast(frame.*.nb_samples);
        const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));
        for (data[0][0..nb]) |s| max_amp = @max(max_amp, @abs(s));
    }
    try std.testing.expect(max_amp > 0.2);
}
