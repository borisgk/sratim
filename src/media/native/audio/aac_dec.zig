const std = @import("std");

pub const decoder = @import("aac/decoder.zig");
pub const AacDecoder = decoder.AacDecoder;
pub const tables = @import("aac/tables.zig");
pub const huffman = @import("aac/huffman.zig");

test "AacDecoder initialization and reset" {
    var dec = AacDecoder.init();
    try std.testing.expectEqual(@as(u32, 48000), dec.sample_rate);
    try std.testing.expectEqual(@as(u32, 6), dec.channels);
    dec.reset();
}
