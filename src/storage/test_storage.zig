const std = @import("std");
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const logs_engine = @import("logs_engine.zig");

test "SratimStorage: CRUD, concurrency, and snapshot roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_sratim.json";
    const wal_path = "tmp/test_sratim.wal";
    const persons_dir = "tmp/test_sratim_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
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
    try testing.expectEqual(schema.LibraryType.Movies, lib.lib_type);

    // 3. Add Movie
    const mov = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib.id,
        .file_path = "/path/to/movies/Matrix.mkv",
        .clean_name = "The Matrix",
        .title = "The Matrix",
        .is_present = true,
    });
    try testing.expectEqual(@as(i64, 1), mov);

    // 4. Add Show and Episode
    const show_id = try storage.addOrUpdateShow(.{
        .id = 0,
        .library_id = lib.id,
        .path = "/path/to/shows/Breaking Bad",
        .title = "Breaking Bad",
        .is_present = true,
    });
    try testing.expectEqual(@as(i64, 1), show_id);

    const ep_id = try storage.addOrUpdateEpisode(.{
        .id = 0,
        .show_id = show_id,
        .season = 1,
        .episode = 1,
        .file_path = "/path/to/shows/Breaking Bad/S01E01.mkv",
        .title = "Pilot",
        .is_present = true,
    });
    try testing.expectEqual(@as(i64, 1), ep_id);

    // 5. Test Snapshot Save
    try storage.snapshot();

    // 6. Test Loading into clean storage instance
    var restored = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
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
    const persons_dir = "tmp/test_credits_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
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

    var restored = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
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

test "SratimStorage: Credits backfill tracking and querying" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_backfill.json";
    const wal_path = "tmp/test_backfill.wal";
    const persons_dir = "tmp/test_backfill_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    const lib = try storage.addLibrary("Movies", "/tmp/movies", .Movies);
    const lib_id = lib.id;

    // Movie 1: has TMDB ID, no credits fetched
    const m1_id = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib_id,
        .file_path = "m1.mkv",
        .clean_name = "Movie 1",
        .tmdb_id = 100,
        .is_present = true,
        .credits_fetched = false,
    });

    // Movie 2: has TMDB ID, credits_fetched = true
    const m2_id = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib_id,
        .file_path = "m2.mkv",
        .clean_name = "Movie 2",
        .tmdb_id = 200,
        .is_present = true,
        .credits_fetched = true,
    });

    // Movie 3: has NO TMDB ID
    _ = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib_id,
        .file_path = "m3.mkv",
        .clean_name = "Movie 3",
        .tmdb_id = null,
        .is_present = true,
    });

    // Query missing credits -> only m1 should be returned
    const missing = try storage.getMoviesMissingCredits(allocator);
    defer {
        for (missing) |*m| m.deinit(allocator);
        allocator.free(missing);
    }
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqual(m1_id, missing[0].id);

    // Mark m1 fetched
    storage.markMovieCreditsFetched(m1_id);

    // Query missing again -> should be 0
    const missing_after = try storage.getMoviesMissingCredits(allocator);
    defer {
        for (missing_after) |*m| m.deinit(allocator);
        allocator.free(missing_after);
    }
    try testing.expectEqual(@as(usize, 0), missing_after.len);

    // Test snapshot roundtrip preserves credits_fetched
    try storage.snapshot();

    var restored = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer restored.deinit();
    try testing.expect(try restored.load());

    const restored_m1 = (try restored.getMovieById(allocator, m1_id)).?;
    defer {
        var m = restored_m1;
        m.deinit(allocator);
    }
    try testing.expect(restored_m1.credits_fetched);

    const restored_m2 = (try restored.getMovieById(allocator, m2_id)).?;
    defer {
        var m = restored_m2;
        m.deinit(allocator);
    }
    try testing.expect(restored_m2.credits_fetched);
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
    const persons_dir = "tmp/test_compat_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

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

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    const loaded = try storage.load();
    try testing.expect(loaded);
    try testing.expectEqual(@as(i64, 42), storage.next_user_id);
    try testing.expectEqual(@as(usize, 0), storage.countUsers());
    try testing.expectEqual(@as(usize, 0), storage.countMovies());
}

test "SratimStorage: person extended details and backfill tracking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_person_details.json";
    const wal_path = "tmp/test_person_details.wal";
    const persons_dir = "tmp/test_person_details_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    // Add a person without details
    try storage.addOrUpdatePerson(.{
        .id = 500,
        .name = "David Fincher",
        .known_for_department = "Directing",
    });

    // Should be reported in missing details
    const missing = try storage.getPeopleMissingDetails(allocator);
    defer {
        for (missing) |*p| {
            var mut_p = p.*;
            mut_p.deinit(allocator);
        }
        allocator.free(missing);
    }
    try testing.expectEqual(@as(usize, 1), missing.len);
    try testing.expectEqual(@as(i64, 500), missing[0].id);
    try testing.expect(!missing[0].details_fetched);

    // Save details (persisted to cold file on disk)
    try storage.savePersonDetails(
        500,
        "David Fincher bio",
        "1962-08-28",
        null,
        "Denver, Colorado, USA",
        "nm0000399",
        "[{\"id\":100,\"title\":\"Fight Club\"}]",
    );

    // Should no longer be missing
    const missing_after = try storage.getPeopleMissingDetails(allocator);
    defer {
        for (missing_after) |*p| {
            var mut_p = p.*;
            mut_p.deinit(allocator);
        }
        allocator.free(missing_after);
    }
    try testing.expectEqual(@as(usize, 0), missing_after.len);

    // Verify fetched person in memory
    const p_opt = try storage.getPersonById(allocator, 500);
    try testing.expect(p_opt != null);
    var p = p_opt.?;
    defer p.deinit(allocator);
    try testing.expect(p.details_fetched);
    try testing.expect(p.details_updated_at > 0);

    // Verify cold details retrieved from disk on-demand
    const details_parsed_opt = try storage.getPersonDetails(allocator, 500);
    try testing.expect(details_parsed_opt != null);
    var details_parsed = details_parsed_opt.?;
    defer details_parsed.deinit();
    const d = details_parsed.value;
    try testing.expectEqualStrings("David Fincher bio", d.biography.?);
    try testing.expectEqualStrings("1962-08-28", d.birthday.?);
    try testing.expectEqualStrings("Denver, Colorado, USA", d.place_of_birth.?);
    try testing.expectEqualStrings("nm0000399", d.imdb_id.?);
    try testing.expect(d.filmography_json != null);
}

test "Storage: getPeopleNeedingRefresh with jitter and priority ordering" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const snap_path = "tmp/test_refresh_snap.bin";
    const wal_path = "tmp/test_refresh_wal.bin";
    const persons_dir = "tmp/test_refresh_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    const now = storage.now();
    const day: i64 = 86400;

    // Person 0: id % 21 == 0 -> jitter = -10 days -> effective TTL = 20 days
    try storage.addOrUpdatePerson(.{
        .id = 0,
        .name = "Person Early",
        .details_fetched = true,
        .details_updated_at = now - (25 * day), // age 25 days > 20 days -> STALE
    });

    // Person 20: id % 21 == 20 -> jitter = +10 days -> effective TTL = 40 days
    try storage.addOrUpdatePerson(.{
        .id = 20,
        .name = "Person Late",
        .details_fetched = true,
        .details_updated_at = now - (25 * day), // age 25 days < 40 days -> NOT STALE
    });

    // Person 99: unfetched (details_updated_at == 0)
    try storage.addOrUpdatePerson(.{
        .id = 99,
        .name = "Person Unfetched",
        .details_fetched = false,
        .details_updated_at = 0,
    });

    // Person 100: very stale (age 60 days)
    try storage.addOrUpdatePerson(.{
        .id = 100,
        .name = "Person Oldest",
        .details_fetched = true,
        .details_updated_at = now - (60 * day),
    });

    const needing = try storage.getPeopleNeedingRefresh(allocator, 30 * day);
    defer {
        for (needing) |*p| {
            var mut_p = p.*;
            mut_p.deinit(allocator);
        }
        allocator.free(needing);
    }

    // Person 20 should NOT be in the list (effective TTL is 40 days, age is only 25 days)
    // Person 99 (unfetched), Person 100 (60 days old), Person 0 (effective TTL 20 days, age 25 days) SHOULD be in the list
    try testing.expectEqual(@as(usize, 3), needing.len);

    // Unfetched should be first (highest priority)
    try testing.expectEqual(@as(i64, 99), needing[0].id);

    // Oldest fetched should be next (Person 100 with age 60 days before Person 0 with age 25 days)
    try testing.expectEqual(@as(i64, 100), needing[1].id);
    try testing.expectEqual(@as(i64, 0), needing[2].id);
}

test "SratimStorage: legacy person snapshot migration to disk files" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_migration.json";
    const wal_path = "tmp/test_migration.wal";
    const persons_dir = "tmp/test_migration_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    // Create a snapshot containing legacy person fields
    const legacy_json =
        \\{
        \\  "version": 1,
        \\  "next_user_id": 1,
        \\  "next_library_id": 1,
        \\  "next_movie_id": 1,
        \\  "next_show_id": 1,
        \\  "next_episode_id": 1,
        \\  "next_credit_id": 1,
        \\  "users": [],
        \\  "libraries": [],
        \\  "movies": [],
        \\  "shows": [],
        \\  "episodes": [],
        \\  "people": [
        \\    {
        \\      "id": 999,
        \\      "name": "Legacy Person",
        \\      "profile_path": "/legacy.jpg",
        \\      "known_for_department": "Acting",
        \\      "details_fetched": true,
        \\      "biography": "Legacy person bio",
        \\      "birthday": "1980-01-01",
        \\      "deathday": null,
        \\      "place_of_birth": "Legacy City",
        \\      "imdb_id": "nm9999999",
        \\      "filmography_json": "[{\"id\":1,\"title\":\"Legacy Film\"}]",
        \\      "details_updated_at": 123456789
        \\    }
        \\  ],
        \\  "movie_credits": []
        \\}
    ;
    const file = try std.Io.Dir.cwd().createFile(testing.io, snap_path, .{});
    try file.writeStreamingAll(testing.io, legacy_json);
    file.close(testing.io);

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    const loaded = try storage.load();
    try testing.expect(loaded);

    // In-memory person should exist and have details_fetched = true
    const p_opt = try storage.getPersonById(allocator, 999);
    try testing.expect(p_opt != null);
    var p = p_opt.?;
    defer p.deinit(allocator);
    try testing.expect(p.details_fetched);
    try testing.expectEqual(@as(i64, 123456789), p.details_updated_at);
    try testing.expectEqualStrings("Legacy Person", p.name);

    // Cold file should have been migrated to disk!
    const cold_details = try storage.getPersonDetails(allocator, 999);
    try testing.expect(cold_details != null);
    var details = cold_details.?;
    defer details.deinit();
    try testing.expectEqualStrings("Legacy person bio", details.value.biography.?);
    try testing.expectEqualStrings("1980-01-01", details.value.birthday.?);
    try testing.expectEqualStrings("Legacy City", details.value.place_of_birth.?);
    try testing.expectEqualStrings("nm9999999", details.value.imdb_id.?);
    try testing.expectEqualStrings("[{\"id\":1,\"title\":\"Legacy Film\"}]", details.value.filmography_json.?);

    // Now call snapshot() and verify the saved JSON does NOT contain biography in persons
    try storage.snapshot();

    // Verify snapshot file doesn't contain biography
    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, snap_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Legacy person bio") == null);
}

test "SratimStorage: legacy snapshot without details_updated_at is migrated and NOT re-backfilled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_no_updated_at.json";
    const wal_path = "tmp/test_no_updated_at.wal";
    const persons_dir = "tmp/test_no_updated_at_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    // Legacy JSON from commit 8535a27: details_fetched = true, biography present, NO details_updated_at field
    const legacy_json =
        \\{
        \\  "version": 1,
        \\  "next_user_id": 1,
        \\  "next_library_id": 1,
        \\  "next_movie_id": 1,
        \\  "next_show_id": 1,
        \\  "next_episode_id": 1,
        \\  "next_credit_id": 1,
        \\  "users": [],
        \\  "libraries": [],
        \\  "movies": [],
        \\  "shows": [],
        \\  "episodes": [],
        \\  "people": [
        \\    {
        \\      "id": 888,
        \\      "name": "Christopher Nolan",
        \\      "profile_path": "/nolan.jpg",
        \\      "known_for_department": "Directing",
        \\      "details_fetched": true,
        \\      "biography": "Christopher Nolan was born in London...",
        \\      "birthday": "1970-07-30",
        \\      "filmography_json": "[{\"id\":157336,\"title\":\"Interstellar\"}]"
        \\    }
        \\  ],
        \\  "movie_credits": []
        \\}
    ;
    const file = try std.Io.Dir.cwd().createFile(testing.io, snap_path, .{});
    try file.writeStreamingAll(testing.io, legacy_json);
    file.close(testing.io);

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    const loaded = try storage.load();
    try testing.expect(loaded);

    // 1. In-memory person should exist and have details_fetched = true AND details_updated_at > 0
    const p_opt = try storage.getPersonById(allocator, 888);
    try testing.expect(p_opt != null);
    var p = p_opt.?;
    defer p.deinit(allocator);
    try testing.expect(p.details_fetched);
    try testing.expect(p.details_updated_at > 0);

    // 2. Cold file should exist on disk
    const cold_details = try storage.getPersonDetails(allocator, 888);
    try testing.expect(cold_details != null);
    var details = cold_details.?;
    defer details.deinit();
    try testing.expectEqualStrings("Christopher Nolan was born in London...", details.value.biography.?);

    // 3. getPeopleNeedingRefresh MUST NOT return Nolan! (He was migrated, not unfetched!)
    const needing = try storage.getPeopleNeedingRefresh(allocator, 30 * 86400);
    defer {
        for (needing) |*item| {
            var mut_item = item.*;
            mut_item.deinit(allocator);
        }
        allocator.free(needing);
    }
    try testing.expectEqual(@as(usize, 0), needing.len);
}
