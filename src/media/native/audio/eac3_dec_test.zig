const std = @import("std");
const eac3_dec = @import("eac3_dec.zig");
const Eac3Decoder = eac3_dec.Eac3Decoder;

test "Eac3Decoder basic initialization" {
    const testing = std.testing;
    const dec = Eac3Decoder.init();
    try testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try testing.expectEqual(@as(u32, 6), dec.channels);
}
