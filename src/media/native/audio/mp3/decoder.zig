const std = @import("std");

const c = @cImport({
    @cDefine("MINIMP3_FLOAT_OUTPUT", "");
    @cInclude("minimp3.h");
});

pub const Mp3Decoder = struct {
    sample_rate: u32 = 44100,
    channels: u16 = 2,
    bitrate_kbps: u16 = 128,
    dec: c.mp3dec_t = undefined,

    pub fn init() Mp3Decoder {
        var self: Mp3Decoder = .{};
        c.mp3dec_init(&self.dec);
        return self;
    }

    pub fn reset(self: *Mp3Decoder) void {
        c.mp3dec_init(&self.dec);
    }

    /// Decodes an MP3 frame into interleaved stereo 32-bit float PCM samples.
    /// out_interleaved must have room for at least 1152 * 2 samples.
    /// Returns the number of stereo samples decoded (typically 1152 for MPEG-1, 576 for MPEG-2).
    pub fn decodeFrame(
        self: *Mp3Decoder,
        in_payload: []const u8,
        out_interleaved: []f32,
    ) !usize {
        if (in_payload.len == 0) return error.BufferTooSmall;
        if (out_interleaved.len < 1152 * 2) return error.BufferTooSmall;

        var info: c.mp3dec_frame_info_t = undefined;
        const samples = c.mp3dec_decode_frame(
            &self.dec,
            in_payload.ptr,
            @intCast(in_payload.len),
            out_interleaved.ptr,
            &info,
        );

        if (info.frame_bytes == 0 or samples <= 0) {
            return error.InvalidData;
        }

        self.sample_rate = @intCast(info.hz);
        self.channels = @intCast(info.channels);
        self.bitrate_kbps = @intCast(info.bitrate_kbps);

        // If mono, upmix mono channel in-place to stereo interleaved
        if (info.channels == 1) {
            var i: usize = @intCast(samples);
            while (i > 0) {
                i -= 1;
                const s = out_interleaved[i];
                out_interleaved[i * 2] = s;
                out_interleaved[i * 2 + 1] = s;
            }
        }

        return @intCast(samples);
    }
};

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
