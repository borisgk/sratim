const std = @import("std");
const mp3_dec = @import("mp3_dec.zig");
const Mp3Decoder = mp3_dec.Mp3Decoder;

test "Mp3Decoder initialization and reset" {
    var dec = Mp3Decoder.init();
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    dec.reset();
}
