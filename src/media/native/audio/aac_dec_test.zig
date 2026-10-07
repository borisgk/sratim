const std = @import("std");
const aac_dec = @import("aac_dec.zig");
const AacDecoder = aac_dec.AacDecoder;

test "AacDecoder initialization and reset" {
    var dec = AacDecoder.init();
    try std.testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try std.testing.expectEqual(@as(u32, 6), dec.channels);
    dec.reset();
}
