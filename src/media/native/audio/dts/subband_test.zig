const std = @import("std");
const subband = @import("subband.zig");

test "clip23 and fixed math sanity" {
    try std.testing.expectEqual(@as(i32, 8388607), subband.clip23(10000000));
    try std.testing.expectEqual(@as(i32, -8388608), subband.clip23(-10000000));
    try std.testing.expectEqual(@as(i32, 100), subband.clip23(100));
    try std.testing.expectEqual(@as(i32, 2), subband.norm__(16, 3));
}
