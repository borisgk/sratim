const std = @import("std");
const native_metadata = @import("native/metadata.zig");
const config_mod = @import("../config.zig");

/// Returns the actual keyframe PTS for a given seek position using pure Zig container inspection.
pub fn getKeyframePts(io: std.Io, file_path: []const u8, start_time: f64, audio_idx_requested: c_int, mode: config_mod.EngineMode) f64 {
    _ = audio_idx_requested;
    _ = mode;
    return native_metadata.getKeyframePts(io, file_path, start_time) catch start_time;
}
