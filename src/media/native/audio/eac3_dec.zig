const std = @import("std");

pub const tables = @import("eac3/tables.zig");
pub const decoder = @import("eac3/decoder.zig");
pub const Eac3Decoder = decoder.Eac3Decoder;

test "Eac3Decoder basic initialization" {
    const testing = std.testing;
    const dec = Eac3Decoder.init();
    try testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try testing.expectEqual(@as(u32, 6), dec.channels);
}
