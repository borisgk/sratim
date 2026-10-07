const std = @import("std");
const native_subtitles = @import("subtitles.zig");

test "extractMkvSubtitlesVtt from test_sync.mkv" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try native_subtitles.extractMkvSubtitlesVtt(allocator, io, &aw.writer, "tests/test_sync.mkv", 2, 0.0);
    const text = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "WEBVTT\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "-->") != null);
}

test "extractNativeSubtitlesVtt from test_subs.mp4" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try native_subtitles.extractNativeSubtitlesVtt(allocator, io, &aw.writer, "tests/test_subs.mp4", 2, 0.0);
    const text = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "WEBVTT\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "00:00:01.000 --> 00:00:03.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello MP4 Subtitles!") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "00:00:05.000 --> 00:00:07.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Second MP4 Cue") != null);
}

test "peekSubtitleSample from test_subs.mp4" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const peek_text = (try native_subtitles.peekSubtitleSample(allocator, io, "tests/test_subs.mp4", 2)) orelse return error.TestFailed;
    defer allocator.free(peek_text);

    try std.testing.expect(std.mem.indexOf(u8, peek_text, "Hello MP4 Subtitles!") != null);
}

test "extractMkvSubtitlesVtt from Ludwig S02E01" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/Users/borisk/Movies/Sratim/Shows/Ludwig/Ludwig 2024 S02E01 1080p WEB-DL HEVC x265-RMTeam.mkv";

    // Stream 2 (English original)
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try native_subtitles.extractNativeSubtitlesVtt(allocator, io, &aw.writer, path, 2, 0.0);
        const text = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, text, "WEBVTT\n\n"));
        try std.testing.expect(text.len > 100);
    }

    // Stream 3 (English SDH)
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try native_subtitles.extractNativeSubtitlesVtt(allocator, io, &aw.writer, path, 3, 0.0);
        const text = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, text, "WEBVTT\n\n"));
        try std.testing.expect(text.len > 100);
    }
}

test "peekSubtitleSample from Ludwig S02E01" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/Users/borisk/Movies/Sratim/Shows/Ludwig/Ludwig 2024 S02E01 1080p WEB-DL HEVC x265-RMTeam.mkv";
    const peek_text = (try native_subtitles.peekSubtitleSample(allocator, io, path, 2)) orelse return error.TestFailed;
    defer allocator.free(peek_text);

    try std.testing.expect(peek_text.len > 0);
}
