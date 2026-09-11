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

test "SratimStorage: Credits, Persons, and filmography lookups" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_credits.json";
    const wal_path = "tmp/test_credits.wal";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path);
    defer storage.deinit();

    // 1. Create a movie
    const lib = try storage.addLibrary("Movies", "/movies", .Movies);
    const mov_id = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib.id,
        .file_path = "/movies/Inception.mkv",
        .clean_name = "Inception",
        .is_present = true,
    });

    // 2. Add Person (Leonardo DiCaprio - TMDB 6193) and Director (Christopher Nolan - TMDB 525)
    try storage.addOrUpdatePerson(.{
        .id = 6193,
        .name = "Leonardo DiCaprio",
        .profile_path = "/wo2tpe19lP71a399x47xVqUq8A.jpg",
        .known_for_department = "Acting",
    });
    try storage.addOrUpdatePerson(.{
        .id = 525,
        .name = "Christopher Nolan",
        .profile_path = "/xuAIuYSmsUzKlUMBFGVZaWsY3Z5.jpg",
        .known_for_department = "Directing",
    });

    // 3. Add Credits
    _ = try storage.addMovieCredit(.{
        .id = 0,
        .movie_id = mov_id,
        .person_id = 6193,
        .name = "Leonardo DiCaprio",
        .character = "Dom Cobb",
        .department = "Acting",
        .profile_path = "/wo2tpe19lP71a399x47xVqUq8A.jpg",
        .order = 0,
        .is_cast = true,
    });
    _ = try storage.addMovieCredit(.{
        .id = 0,
        .movie_id = mov_id,
        .person_id = 525,
        .name = "Christopher Nolan",
        .job = "Director",
        .department = "Directing",
        .profile_path = "/xuAIuYSmsUzKlUMBFGVZaWsY3Z5.jpg",
        .order = 0,
        .is_cast = false,
    });

    // 4. Query Credits for movie
    const credits = try storage.getCreditsByMovie(allocator, mov_id);
    defer {
        for (credits) |*c| c.deinit(allocator);
        allocator.free(credits);
    }
    try testing.expectEqual(@as(usize, 2), credits.len);
    try testing.expect(credits[0].is_cast); // Cast first
    try testing.expectEqualStrings("Leonardo DiCaprio", credits[0].name);
    try testing.expectEqualStrings("Dom Cobb", credits[0].character.?);
    try testing.expect(!credits[1].is_cast); // Crew next
    try testing.expectEqualStrings("Christopher Nolan", credits[1].name);

    // 5. Query filmography by person
    const nolan_movies = try storage.getMoviesByPerson(allocator, 525);
    defer {
        for (nolan_movies) |*m| m.deinit(allocator);
        allocator.free(nolan_movies);
    }
    try testing.expectEqual(@as(usize, 1), nolan_movies.len);
    try testing.expectEqualStrings("Inception", nolan_movies[0].clean_name);

    // 6. Snapshot roundtrip
    try storage.snapshot();

    var restored = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path);
    defer restored.deinit();
    const loaded = try restored.load();
    try testing.expect(loaded);

    const leo_person = (try restored.getPersonById(allocator, 6193)).?;
    defer {
        var p = leo_person;
        p.deinit(allocator);
    }
    try testing.expectEqualStrings("Leonardo DiCaprio", leo_person.name);

    const restored_credits = try restored.getCreditsByMovie(allocator, mov_id);
    defer {
        for (restored_credits) |*c| c.deinit(allocator);
        allocator.free(restored_credits);
    }
    try testing.expectEqual(@as(usize, 2), restored_credits.len);

    var people_map = try restored.getMoviePeopleNamesMap(allocator);
    defer {
        var it = people_map.iterator();
        while (it.next()) |e| allocator.free(e.value_ptr.*);
        people_map.deinit();
    }
    try testing.expect(people_map.contains(mov_id));
    const names = people_map.get(mov_id).?;
    try testing.expect(std.mem.indexOf(u8, names, "Leonardo DiCaprio") != null);
    try testing.expect(std.mem.indexOf(u8, names, "Christopher Nolan") != null);
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

test "LogsStorage: WAL crash recovery without snapshot" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_crash_logs.json";
    const wal_path = "tmp/test_crash_logs.wal";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    {
        var logs_storage = logs_engine.LogsStorage.init(allocator, testing.io, snap_path, wal_path);
        defer logs_storage.deinitWithoutSnapshot();
        // Mutate in-memory and write WAL, but DO NOT snapshot
        try logs_storage.savePlaybackProgress("user1", 100, 450.0, 7200.0);
        try logs_storage.saveEpisodePlaybackProgress("user1", 200, 310.0, 3600.0);
        try logs_storage.logPlaybackEvent("user1", 100, "progress", 450.0);
    }

    // Recover from WAL
    var restored = logs_engine.LogsStorage.init(allocator, testing.io, snap_path, wal_path);
    defer restored.deinit();

    const loaded = try restored.load();
    try testing.expect(loaded);
    try testing.expectApproxEqAbs(@as(f64, 450.0), restored.getPlaybackProgress("user1", 100), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 310.0), restored.getEpisodePlaybackProgress("user1", 200), 0.01);

    const recent = try restored.getRecentlyWatched(allocator, "user1", 10);
    defer allocator.free(recent);
    try testing.expectEqual(@as(usize, 2), recent.len);
}

test "LogsStorage: Corrupted / truncated WAL tail recovery" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_corrupt_logs.json";
    const wal_path = "tmp/test_corrupt_logs.wal";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    {
        var logs_storage = logs_engine.LogsStorage.init(allocator, testing.io, snap_path, wal_path);
        defer logs_storage.deinitWithoutSnapshot();
        try logs_storage.savePlaybackProgress("charlie", 88, 600.0, 1800.0);
    }

    // Append garbage / partial write to simulating mid-crash power failure
    const file = try std.Io.Dir.cwd().createFile(testing.io, wal_path, .{ .truncate = false });
    const offset = try file.length(testing.io);
    const garbage = [_]u8{ 'W', 'A', 'L', '1', 0xff, 0xff, 0x00, 0x00, 0x12, 0x34 };
    try file.writePositionalAll(testing.io, &garbage, offset);
    file.close(testing.io);

    // Reopen and ensure valid record before corruption is recovered safely
    var restored = logs_engine.LogsStorage.init(allocator, testing.io, snap_path, wal_path);
    defer restored.deinit();

    const loaded = try restored.load();
    try testing.expect(loaded);
    try testing.expectApproxEqAbs(@as(f64, 600.0), restored.getPlaybackProgress("charlie", 88), 0.01);
}

test "SratimStorage: JSON with missing array fields backwards compatibility" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_compat_sratim.json";
    const wal_path = "tmp/test_compat_sratim.wal";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};

    // Minimal JSON with only version and next IDs, missing users, movies, etc.
    const minimal_json =
        \\{
        \\  "version": 1,
        \\  "next_user_id": 42
        \\}
    ;
    const file = try std.Io.Dir.cwd().createFile(testing.io, snap_path, .{});
    try file.writeStreamingAll(testing.io, minimal_json);
    file.close(testing.io);

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path);
    defer storage.deinit();

    const loaded = try storage.load();
    try testing.expect(loaded);
    try testing.expectEqual(@as(i64, 42), storage.next_user_id);
    try testing.expectEqual(@as(usize, 0), storage.countUsers());
    try testing.expectEqual(@as(usize, 0), storage.countMovies());
}



