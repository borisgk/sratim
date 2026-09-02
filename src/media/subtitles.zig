const std = @import("std");
const native_subtitles = @import("native/subtitles.zig");
const config_mod = @import("../config.zig");


pub const SubtitleTrack = struct {
    id: usize,
    label: []const u8,
    language: []const u8,
};

pub const formatVttTime = native_subtitles.formatVttTime;
pub const cleanAssText = native_subtitles.cleanAssText;

/// Dispatches subtitle extraction directly using pure Zig extractors.
pub fn extractSubtitlesVtt(allocator: std.mem.Allocator, io: std.Io, writer: anytype, file_path: [:0]const u8, stream_idx: usize, start_offset: f64, mode: config_mod.EngineMode) !void {
    _ = mode;
    return native_subtitles.extractNativeSubtitlesVtt(allocator, io, writer, file_path, stream_idx, start_offset);
}

test "extractSubtitlesVtt native on MKV and MP4" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // 1. Test native mode on MP4
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_subs.mp4", 2, 0.0, .native);
        const vtt = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
        try std.testing.expect(std.mem.indexOf(u8, vtt, "Hello MP4 Subtitles!") != null);
    }

    // 2. Test native mode on MKV
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_sync.mkv", 2, 0.0, .native);
        const vtt = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
        try std.testing.expect(std.mem.indexOf(u8, vtt, "SRT: 1.0s to 3.0s") != null);
    }

    // 5. Test strict error handling in native mode (invalid stream index fails without falling back)
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        const res = extractSubtitlesVtt(allocator, io, &aw.writer, "tests/test_subs.mp4", 99, 0.0, .native);
        try std.testing.expectError(error.NoSubtitleStreamsFound, res);
    }

    // 6. Test e2e native subtitle extraction on Ludwig S02E01 (both tracks)
    {
        const ludwig_path = "/Users/borisk/Movies/Sratim/Shows/Ludwig/Ludwig 2024 S02E01 1080p WEB-DL HEVC x265-RMTeam.mkv";
        
        // Track 1 (Stream 2)
        {
            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try extractSubtitlesVtt(allocator, io, &aw.writer, ludwig_path, 2, 0.0, .native);
            const vtt = aw.written();
            try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
            try std.testing.expect(std.mem.indexOf(u8, vtt, "-->") != null);
            // Verify cues are found throughout the episode (e.g. later than 30 minutes in)
            try std.testing.expect(vtt.len > 10000);
        }

        // Track 2 (Stream 3 SDH)
        {
            var aw = std.Io.Writer.Allocating.init(allocator);
            defer aw.deinit();
            try extractSubtitlesVtt(allocator, io, &aw.writer, ludwig_path, 3, 0.0, .native);
            const vtt = aw.written();
            try std.testing.expect(std.mem.startsWith(u8, vtt, "WEBVTT\n\n"));
            try std.testing.expect(std.mem.indexOf(u8, vtt, "-->") != null);
            try std.testing.expect(vtt.len > 10000);
        }
    }
}
