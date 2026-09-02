const std = @import("std");

pub const decoder = @import("mp3/decoder.zig");
pub const Mp3Decoder = decoder.Mp3Decoder;

test "Mp3Decoder initialization and reset" {
    var dec = Mp3Decoder.init();
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    dec.reset();
}
