const std = @import("std");
const native_metadata = @import("metadata.zig");

test "inspect sample MKVs metadata" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Verify Polly.mkv
    if (native_metadata.getMediaInfo(allocator, io, "tests/Polly.mkv")) |info| {
        defer info.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), info.subtitle_tracks.len);
        try std.testing.expectEqualStrings("English", info.subtitle_tracks[0].label);
        try std.testing.expectEqualStrings("eng", info.subtitle_tracks[0].language);
    } else |_| {}

    // Verify test_sync.mkv
    if (native_metadata.getMediaInfo(allocator, io, "tests/test_sync.mkv")) |info| {
        defer info.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), info.subtitle_tracks.len);
        try std.testing.expectEqualStrings("English SRT", info.subtitle_tracks[0].label);
        try std.testing.expectEqualStrings("Hebrew ASS", info.subtitle_tracks[1].label);
        try std.testing.expectEqual(@as(usize, 1), info.audio_tracks.len);
        try std.testing.expectEqualStrings("Audio Track 1", info.audio_tracks[0].label);
    } else |_| {}

    // Verify Reacher.mkv automated detection
    if (native_metadata.getMediaInfo(allocator, io, "tests/Reacher.mkv")) |info| {
        defer info.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 37), info.subtitle_tracks.len);
        // Verify key language detections
        try std.testing.expectEqualStrings("English", info.subtitle_tracks[0].label);
        try std.testing.expectEqualStrings("Basque", info.subtitle_tracks[1].label);
        try std.testing.expectEqualStrings("Spanish", info.subtitle_tracks[2].label);
        try std.testing.expectEqualStrings("French", info.subtitle_tracks[3].label);
        try std.testing.expectEqualStrings("Czech", info.subtitle_tracks[5].label);
        try std.testing.expectEqualStrings("German", info.subtitle_tracks[13].label);
        try std.testing.expectEqualStrings("Greek", info.subtitle_tracks[14].label);
        try std.testing.expectEqualStrings("Hebrew", info.subtitle_tracks[15].label);
        try std.testing.expectEqualStrings("Hindi", info.subtitle_tracks[16].label);
        try std.testing.expectEqualStrings("Japanese", info.subtitle_tracks[20].label);
        try std.testing.expectEqualStrings("Kannada", info.subtitle_tracks[21].label);
        try std.testing.expectEqualStrings("Korean", info.subtitle_tracks[22].label);
        try std.testing.expectEqualStrings("Arabic", info.subtitle_tracks[26].label);
        try std.testing.expectEqualStrings("Chinese", info.subtitle_tracks[30].label);
        try std.testing.expectEqualStrings("Turkish", info.subtitle_tracks[36].label);
    } else |_| {}
}
