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
