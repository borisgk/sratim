const std = @import("std");

pub const decoder = @import("mp3/decoder.zig");
pub const Mp3Decoder = decoder.Mp3Decoder;
pub const tables = @import("mp3/tables.zig");
pub const huffman = @import("mp3/huffman.zig");
pub const bit_reader = @import("mp3/bit_reader.zig");
pub const imdct = @import("mp3/imdct.zig");
pub const synthesis = @import("mp3/synthesis.zig");

test "Mp3Decoder initialization and reset" {
    var dec = Mp3Decoder.init();
    try std.testing.expectEqual(@as(u32, 44100), dec.sample_rate);
    try std.testing.expectEqual(@as(u16, 2), dec.channels);
    dec.reset();
}
