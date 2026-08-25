const std = @import("std");

pub const types = @import("isobmff/types.zig");
pub const reader = @import("isobmff/reader.zig");
pub const samples = @import("isobmff/samples.zig");
pub const tracks = @import("isobmff/tracks.zig");
pub const parser = @import("isobmff/parser.zig");

// Re-export public types
pub const BoxHeader = types.BoxHeader;
pub const SttsEntry = types.SttsEntry;
pub const CttsEntry = types.CttsEntry;
pub const StscEntry = types.StscEntry;
pub const SubtitleSample = types.SubtitleSample;
pub const Mp4SubtitleTrack = types.Mp4SubtitleTrack;
pub const MediaSample = types.MediaSample;
pub const Mp4MediaTrack = types.Mp4MediaTrack;
pub const Mp4SubtitleTrackInfo = types.Mp4SubtitleTrackInfo;
pub const Mp4Media = types.Mp4Media;
pub const IdentityMatrix = types.IdentityMatrix;

// Re-export reader and box utilities
pub const readBoxHeader = reader.readBoxHeader;
pub const skipBytes = reader.skipBytes;
pub const isFourCC = reader.isFourCC;
pub const isMp4Container = reader.isMp4Container;
pub const isSubtitleHandler = reader.isSubtitleHandler;

// Re-export sample mapping functions
pub const buildSampleList = samples.buildSampleList;
pub const buildMediaSampleList = samples.buildMediaSampleList;

// Re-export track and container parsers
pub const parseSubtitleTrackBox = tracks.parseSubtitleTrackBox;
pub const parseGenericTrackBox = tracks.parseGenericTrackBox;
pub const parseMp4SubtitleTrack = parser.parseMp4SubtitleTrack;
pub const parseMp4Media = parser.parseMp4Media;

test "isMp4Container detection" {
    const ftyp_buf = [_]u8{ 0, 0, 0, 20, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm' };
    try std.testing.expect(isMp4Container(&ftyp_buf));

    const mkv_buf = [_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x93, 0x42, 0x82, 0x88 };
    try std.testing.expect(!isMp4Container(&mkv_buf));
}

test "buildMediaSampleList calculation" {
    const allocator = std.testing.allocator;

    const stts = [_]SttsEntry{
        .{ .count = 2, .delta = 1000 },
    };
    const ctts = [_]CttsEntry{
        .{ .count = 1, .offset = 500 },
        .{ .count = 1, .offset = -200 },
    };
    const stss = [_]u32{1};
    const stsc = [_]StscEntry{
        .{ .first_chunk = 1, .samples_per_chunk = 2, .sample_desc_index = 1 },
    };
    const stsz = [_]u32{ 120, 150 };
    const stco = [_]u64{1000};

    const media_samples = try buildMediaSampleList(
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
