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
