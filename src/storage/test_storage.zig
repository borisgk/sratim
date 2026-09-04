const std = @import("std");
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const logs_engine = @import("logs_engine.zig");

test "SratimStorage: CRUD, concurrency, and snapshot roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_sratim.json";
    const wal_path = "tmp/test_sratim.wal";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path);
    defer storage.deinit();

    // 1. Create Users
    const admin = try storage.createUser("admin", "hash123", "salt123", true);
    try testing.expectEqual(@as(i64, 1), admin.id);
    try testing.expectEqualStrings("admin", admin.username);
    try testing.expect(admin.is_admin);

    const user_lookup = storage.getUser("admin");
    try testing.expect(user_lookup != null);
    try testing.expectEqualStrings("admin", user_lookup.?.username);

    // 2. Create Library
    const lib = try storage.addLibrary("Action Movies", "/path/to/movies", .Movies);
    try testing.expectEqual(@as(i64, 1), lib.id);
    try testing.expectEqualStrings("Action Movies", lib.name);

    // 3. Create Movie
    const mov_id = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib.id,
        .file_path = "/path/to/movies/Matrix.mkv",
        .clean_name = "Matrix",
        .is_present = true,
        .file_size = 1024 * 1024 * 500,
    });
    try testing.expectEqual(@as(i64, 1), mov_id);

    try storage.linkMovieMetadata(mov_id, 603, "The Matrix", "A computer hacker learns...", "/poster.jpg", "/backdrop.jpg", "1999-03-31");

    const fetched_mov = (try storage.getMovieById(allocator, mov_id)).?;
    defer {
        var m = fetched_mov;
        m.deinit(allocator);
    }
    try testing.expectEqualStrings("The Matrix", fetched_mov.title.?);
    try testing.expectEqual(@as(?i64, 603), fetched_mov.tmdb_id);

    // 4. Create Show & Episode
    const show_id = try storage.addOrUpdateShow(.{
        .id = 0,
        .library_id = lib.id,
        .path = "/path/to/shows/Breaking Bad",
        .title = "Breaking Bad",
    });
    try testing.expectEqual(@as(i64, 1), show_id);

    const ep_id = try storage.addOrUpdateEpisode(.{
        .id = 0,
        .show_id = show_id,
        .file_path = "/path/to/shows/Breaking Bad/S01E01.mkv",
        .season = 1,
        .episode = 1,
        .title = "Pilot",
    });
    try testing.expectEqual(@as(i64, 1), ep_id);

    // 5. Test Snapshot Save
    try storage.snapshot();

    // 6. Test Loading into clean storage instance
    var restored = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path);
    defer restored.deinit();

    const loaded = try restored.load();
    try testing.expect(loaded);
    try testing.expectEqual(@as(usize, 1), restored.countUsers());
    try testing.expectEqual(@as(usize, 1), restored.countLibraries());
    try testing.expectEqual(@as(usize, 1), restored.countMovies());
    try testing.expectEqual(@as(usize, 1), restored.countShows());
    try testing.expectEqual(@as(usize, 1), restored.countEpisodes());

    const restored_movie = (try restored.getMovieById(allocator, 1)).?;
    defer {
        var rm = restored_movie;
        rm.deinit(allocator);
    }
    try testing.expectEqualStrings("The Matrix", restored_movie.title.?);
}

test "LogsStorage: Progress, logs, and recently watched" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_logs.json";
    const wal_path = "tmp/test_logs.wal";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    var logs_storage = logs_engine.LogsStorage.init(allocator, testing.io, snap_path, wal_path);
    defer logs_storage.deinit();

    // 1. Save and query progress
    try logs_storage.savePlaybackProgress("alice", 42, 120.5, 3600.0);
    const pos = logs_storage.getPlaybackProgress("alice", 42);
    try testing.expectApproxEqAbs(@as(f64, 120.5), pos, 0.01);

    // 2. Playback log
    try logs_storage.logPlaybackEvent("alice", 42, "progress", 120.5);
    try testing.expectEqual(@as(usize, 1), logs_storage.playback_logs.items.len);

    // 3. Recently watched
    const recent = try logs_storage.getRecentlyWatched(allocator, "alice", 10);
    defer allocator.free(recent);
    try testing.expectEqual(@as(usize, 1), recent.len);
    try testing.expectEqual(@as(i64, 42), recent[0].item_id);
    try testing.expectApproxEqAbs(@as(f64, 120.5), recent[0].position, 0.01);

    // 4. Snapshot roundtrip
    try logs_storage.snapshot();

    var restored = logs_engine.LogsStorage.init(allocator, testing.io, snap_path, wal_path);
    defer restored.deinit();

    const loaded = try restored.load();
    try testing.expect(loaded);
    try testing.expectApproxEqAbs(@as(f64, 120.5), restored.getPlaybackProgress("alice", 42), 0.01);
}


