const std = @import("std");
const isobmff = @import("../isobmff.zig");
const vtt = @import("vtt.zig");

/// Peeks a small sample of text from an MP4 subtitle stream for language detection.
pub fn peekMp4SubtitleSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    target_stream_idx: usize,
) !?[]u8 {
    var track = (isobmff.parseMp4SubtitleTrack(allocator, io, file_path, target_stream_idx) catch null) orelse return null;
    defer track.deinit(allocator);

    if (track.samples.len == 0) return null;

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    var sample_buf = std.ArrayList(u8).empty;
    defer sample_buf.deinit(allocator);

    var text_buf = std.ArrayList(u8).empty;
    defer text_buf.deinit(allocator);

    var cues_collected: usize = 0;
    for (track.samples) |sample| {
        if (sample.size == 0) continue;

        file_reader.seekTo(sample.offset) catch continue;
        const sample_data = allocator.alloc(u8, sample.size) catch continue;
        defer allocator.free(sample_data);

        file_reader.interface.readSliceAll(sample_data) catch continue;

        text_buf.clearRetainingCapacity();
        vtt.cleanMovText(&text_buf, allocator, sample_data) catch continue;
        const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
        if (trimmed.len > 0) {
            if (sample_buf.items.len > 0) try sample_buf.append(allocator, ' ');
            try sample_buf.appendSlice(allocator, trimmed);
            cues_collected += 1;
            if (cues_collected >= 3 or sample_buf.items.len >= 300) {
                return try sample_buf.toOwnedSlice(allocator);
            }
        }
    }

    if (sample_buf.items.len > 0) {
        return try sample_buf.toOwnedSlice(allocator);
    }
    return null;
}

/// Pure Zig extraction of embedded subtitles from an MP4/MOV file directly to a WebVTT writer.
pub fn extractMp4SubtitlesVtt(
    allocator: std.mem.Allocator,
    io: std.Io,
    writer: anytype,
    file_path: [:0]const u8,
    target_stream_idx: usize,
    start_offset: f64,
) !void {
    var track = (try isobmff.parseMp4SubtitleTrack(allocator, io, file_path, target_stream_idx)) orelse return error.NoSubtitleStreamsFound;
    defer track.deinit(allocator);

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    try writer.writeAll("WEBVTT\n\n");

    var text_buf = std.ArrayList(u8).empty;
    defer text_buf.deinit(allocator);

    for (track.samples) |sample| {
        if (sample.size == 0 or sample.end_sec < start_offset) continue;

        try file_reader.seekTo(sample.offset);
        const sample_data = try allocator.alloc(u8, sample.size);
        defer allocator.free(sample_data);

        try file_reader.interface.readSliceAll(sample_data);

        text_buf.clearRetainingCapacity();
        try vtt.cleanMovText(&text_buf, allocator, sample_data);
        const trimmed = std.mem.trim(u8, text_buf.items, " \t\r\n");
        if (trimmed.len > 0) {
            try vtt.formatVttTime(writer, sample.start_sec);
            try writer.writeAll(" --> ");
            try vtt.formatVttTime(writer, sample.end_sec);
            try writer.writeAll("\n");
            try writer.writeAll(trimmed);
            try writer.writeAll("\n\n");
        }
    }
}
