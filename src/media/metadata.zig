const std = @import("std");
const native_metadata = @import("native/metadata.zig");
const config_mod = @import("../config.zig");

/// Returns the actual keyframe PTS for a given seek position using pure Zig container inspection.
pub fn getKeyframePts(io: std.Io, file_path: []const u8, start_time: f64, audio_idx_requested: c_int, mode: config_mod.EngineMode) f64 {
    _ = audio_idx_requested;
    _ = mode;
    return native_metadata.getKeyframePts(io, file_path, start_time) catch start_time;
}

test "inspect native seeking keyframe PTS" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sample_files = [_][]const u8{
        "tests/test_sync.mkv",
        "tests/Reacher.mkv",
        "tests/Polly.mkv",
    };

    for (sample_files) |file_path| {
        const f = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch continue;
        f.close(io);

        const test_seek_times = [_]f64{ 1.0, 3.0, 5.0, 7.0, 15.0, 30.0, 60.0 };
        for (test_seek_times) |seek_time| {
            const native_pts = native_metadata.getKeyframePts(io, file_path, seek_time) catch -1.0;
            try std.testing.expect(native_pts >= 0.0);
            try std.testing.expect(native_pts <= seek_time + 1.0);
        }
    }
}
