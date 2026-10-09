const std = @import("std");
const native_metadata = @import("native/metadata.zig");

test "inspect native seeking keyframe PTS" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const sample_files = [_][]const u8{
        "tests/test_sync.mkv",
        "tests/Reacher.mkv",
        "tests/Polly.mkv",
        "tests/test_subs.mp4",
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

test "fast MP4 keyframe seeking on test_subs.mp4" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const file_path = "tests/test_subs.mp4";
    const f = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch return;
    f.close(io);

    const pts_zero = try native_metadata.getKeyframePts(io, file_path, 0.0);
    try std.testing.expectEqual(@as(f64, 0.0), pts_zero);

    const pts_seek = try native_metadata.getKeyframePts(io, file_path, 5.0);
    try std.testing.expect(pts_seek >= 0.0);
    try std.testing.expect(pts_seek <= 5.0);
}
