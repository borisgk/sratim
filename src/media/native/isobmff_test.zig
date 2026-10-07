const std = @import("std");
const isobmff = @import("isobmff.zig");

test "isMp4Container detection" {
    const ftyp_buf = [_]u8{ 0, 0, 0, 20, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm' };
    try std.testing.expect(isobmff.isMp4Container(&ftyp_buf));

    const mkv_buf = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x93, 0x42, 0x82, 0x88 };
    try std.testing.expect(!isobmff.isMp4Container(&mkv_buf));
}

test "buildMediaSampleList calculation" {
    const allocator = std.testing.allocator;

    const stts = [_]isobmff.SttsEntry{
        .{ .count = 2, .delta = 1000 },
    };
    const ctts = [_]isobmff.CttsEntry{
        .{ .count = 1, .offset = 500 },
        .{ .count = 1, .offset = -200 },
    };
    const stss = [_]u32{1};
    const stsc = [_]isobmff.StscEntry{
        .{ .first_chunk = 1, .samples_per_chunk = 2, .sample_desc_index = 1 },
    };
    const stsz = [_]u32{ 120, 150 };
    const stco = [_]u64{1000};

    const media_samples = try isobmff.buildMediaSampleList(
        allocator,
        1000,
        &stts,
        &ctts,
        &stss,
        true,
        &stsc,
        0,
        &stsz,
        &stco,
    );
    defer allocator.free(media_samples);

    try std.testing.expectEqual(@as(usize, 2), media_samples.len);
    try std.testing.expect(media_samples[0].is_sync);
    try std.testing.expect(!media_samples[1].is_sync);
    try std.testing.expectEqual(@as(u64, 1000), media_samples[0].offset);
    try std.testing.expectEqual(@as(u64, 1120), media_samples[1].offset);
    try std.testing.expectEqual(@as(u64, 500), media_samples[0].pts);
    try std.testing.expectEqual(@as(u64, 800), media_samples[1].pts);
}
