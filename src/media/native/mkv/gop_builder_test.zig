const std = @import("std");
const gop_builder = @import("gop_builder.zig");
const types = @import("types.zig");

test "buildGopMediaSamples timestamp resolution" {
    const allocator = std.testing.allocator;

    const mock_blocks = [_]types.MkvBlock{
        .{ .track_num = 1, .pts_ms = 0, .pts_sec = 0.0, .is_keyframe = true, .is_discardable = false, .payload_offset = 100, .payload_size = 500 },
        .{ .track_num = 1, .pts_ms = 80, .pts_sec = 0.08, .is_keyframe = false, .is_discardable = false, .payload_offset = 600, .payload_size = 300 },
        .{ .track_num = 1, .pts_ms = 40, .pts_sec = 0.04, .is_keyframe = false, .is_discardable = false, .payload_offset = 900, .payload_size = 200 },
    };

    const samples = try gop_builder.buildGopMediaSamples(allocator, &mock_blocks, 1000, 40);
    defer allocator.free(samples);

    try std.testing.expectEqual(@as(usize, 3), samples.len);
    try std.testing.expect(samples[0].is_sync);
    try std.testing.expectEqual(@as(u64, 0), samples[0].dts);
    try std.testing.expectEqual(@as(u64, 0), samples[0].pts);
    try std.testing.expectEqual(@as(i32, 0), samples[0].ctts_offset);

    // B-frame reordering test
    try std.testing.expectEqual(@as(u64, 40), samples[1].dts);
    try std.testing.expectEqual(@as(u64, 80), samples[1].pts);
    try std.testing.expectEqual(@as(i32, 40), samples[1].ctts_offset);

    try std.testing.expectEqual(@as(u64, 80), samples[2].dts);
    try std.testing.expectEqual(@as(u64, 40), samples[2].pts);
    try std.testing.expectEqual(@as(i32, -40), samples[2].ctts_offset);
}
