const std = @import("std");

const transcoder = @import("transcoder.zig");
const isobmff = @import("native/isobmff.zig");
const mp4_streamer = @import("native/mp4_streamer.zig");
const mkv_streamer = @import("native/mkv/mkv_streamer.zig");
const config_mod = @import("../config.zig");

/// Context passed to the streaming pipeline.
pub const HttpStreamContext = struct {
    writer: *std.http.BodyWriter,
    has_error: bool = false,
    keyframe_pts: f64 = 0.0,
};

var log_mutex: std.atomic.Mutex = .unlocked;
var last_logged_path_buf: [1024]u8 = undefined;
var last_logged_path_len: usize = 0;
var last_logged_audio: c_int = -999;

pub fn logStreamStatus(
    file_path: []const u8,
    audio_idx: c_int,
    engine: []const u8,
    video_info: []const u8,
    audio_info: []const u8,
) void {
    while (!log_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer log_mutex.unlock();

    const last_path = last_logged_path_buf[0..last_logged_path_len];
    if (std.mem.eql(u8, file_path, last_path) and audio_idx == last_logged_audio) {
        return;
    }

    const copy_len = @min(file_path.len, last_logged_path_buf.len);
    @memcpy(last_logged_path_buf[0..copy_len], file_path[0..copy_len]);
    last_logged_path_len = copy_len;
    last_logged_audio = audio_idx;

    std.debug.print("[Streamer] File: {s} | Engine: {s} | Video: {s} | Audio: {s}\n", .{
        file_path,
        engine,
        video_info,
        audio_info,
    });
}

/// The main streaming pipeline dispatcher. Dispatches exclusively to native pure Zig slicers.
pub fn streamMedia(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    start_time: f64,
    audio_idx_requested: c_int,
    http_ctx: *HttpStreamContext,
    mode: config_mod.EngineMode,
    audio_transcoder_mode: config_mod.EngineMode,
) !void {
    _ = mode;
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch |err| return err;
    defer file.close(io);

    var file_buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    var magic_buf: [16]u8 = undefined;
    const bytes_read = file_reader.interface.readSliceShort(&magic_buf) catch 0;
    const z_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(z_path);

    if (bytes_read >= 8 and isobmff.isMp4Container(magic_buf[0..bytes_read])) {
        return mp4_streamer.streamMp4(allocator, io, z_path, start_time, audio_idx_requested, http_ctx, audio_transcoder_mode);
    } else {
        return mkv_streamer.streamMkv(allocator, io, z_path, start_time, audio_idx_requested, http_ctx, audio_transcoder_mode);
    }
}

const native_metadata = @import("native/metadata.zig");

pub const SubtitleTrack = native_metadata.SubtitleTrack;
pub const AudioTrack = native_metadata.AudioTrack;
pub const MediaInfo = native_metadata.MediaInfo;

/// Retrieves the duration, codec info, and available audio/subtitle tracks of a media file via pure Zig parsing.
pub fn getMediaInfo(allocator: std.mem.Allocator, io: std.Io, file_path: [:0]const u8, mode: config_mod.EngineMode) !MediaInfo {
    _ = mode;
    return native_metadata.getMediaInfo(allocator, io, file_path);
}
