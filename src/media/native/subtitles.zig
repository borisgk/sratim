const std = @import("std");
const isobmff = @import("isobmff.zig");

pub const vtt = @import("subtitles/vtt.zig");
pub const mkv = @import("subtitles/mkv.zig");
pub const mp4 = @import("subtitles/mp4.zig");

// Re-export text formatting and cleaning helpers
pub const formatVttTime = vtt.formatVttTime;
pub const cleanMovText = vtt.cleanMovText;
pub const cleanAssText = vtt.cleanAssText;

// Re-export container-specific extraction and peeking functions
pub const extractMkvSubtitlesVtt = mkv.extractMkvSubtitlesVtt;
pub const peekMp4SubtitleSample = mp4.peekMp4SubtitleSample;
pub const extractMp4SubtitlesVtt = mp4.extractMp4SubtitlesVtt;

/// Peeks a small sample of text from a specific subtitle stream for language detection.
pub fn peekSubtitleSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    target_stream_idx: usize,
) !?[]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    var magic_buf: [16]u8 = undefined;
    r.readSliceAll(&magic_buf) catch return null;

    if (isobmff.isMp4Container(&magic_buf)) {
        return mp4.peekMp4SubtitleSample(allocator, io, file_path, target_stream_idx);
    } else {
        return mkv.peekMkvSubtitleSample(allocator, io, file_path, target_stream_idx);
    }
}

/// Unified pure Zig subtitle extraction for Matroska (MKV) and ISOBMFF (MP4/MOV) files.
pub fn extractNativeSubtitlesVtt(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    file_path: [:0]const u8,
    target_stream_idx: usize,
    start_offset: f64,
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    const r = &file_reader.interface;

    var magic_buf: [16]u8 = undefined;
    r.readSliceAll(&magic_buf) catch {
        return mkv.extractMkvSubtitlesVtt(allocator, io, writer, file_path, target_stream_idx, start_offset);
    };

    if (isobmff.isMp4Container(&magic_buf)) {
        return mp4.extractMp4SubtitlesVtt(allocator, io, writer, file_path, target_stream_idx, start_offset);
    } else {
        return mkv.extractMkvSubtitlesVtt(allocator, io, writer, file_path, target_stream_idx, start_offset);
    }
}

test "extractMkvSubtitlesVtt from test_sync.mkv" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    try extractMkvSubtitlesVtt(allocator, io, &aw.writer, "tests/test_sync.mkv", 2, 0.0);
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

    try extractNativeSubtitlesVtt(allocator, io, &aw.writer, "tests/test_subs.mp4", 2, 0.0);
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

    const peek_text = (try peekSubtitleSample(allocator, io, "tests/test_subs.mp4", 2)) orelse return error.TestFailed;
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
        try extractNativeSubtitlesVtt(allocator, io, &aw.writer, path, 2, 0.0);
        const text = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, text, "WEBVTT\n\n"));
        try std.testing.expect(text.len > 100);
    }

    // Stream 3 (English SDH)
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try extractNativeSubtitlesVtt(allocator, io, &aw.writer, path, 3, 0.0);
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
    const peek_text = (try peekSubtitleSample(allocator, io, path, 2)) orelse return error.TestFailed;
    defer allocator.free(peek_text);

    try std.testing.expect(peek_text.len > 0);
}
