const std = @import("std");
const engine = @import("../storage/engine.zig");
const logs_engine = @import("../storage/logs_engine.zig");
const analytics = @import("analytics.zig");
const computeReport = analytics.computeReport;

test "analytics: empty logs report" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_analytics_cat.json", "tmp/test_analytics_cat.wal", "tmp/test_analytics_cat_persons");
    defer cat.deinit();

    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_analytics_logs.json", "tmp/test_analytics_logs.wal");
    defer logs.deinit();

    var report = try computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    try std.testing.expectEqual(@as(u64, 0), report.overview.total_watch_seconds);
    try std.testing.expectEqual(@as(u64, 0), report.overview.total_plays);
    try std.testing.expectEqual(@as(u64, 0), report.overview.active_viewers);
    try std.testing.expectEqual(@as(usize, 0), report.top_movies.len);
    try std.testing.expectEqual(@as(usize, 0), report.top_shows.len);
    try std.testing.expectEqual(@as(usize, 0), report.user_activity.len);
    try std.testing.expect(report.daily_trend.len >= 30);
}

test "analytics: watch time aggregation and leaderboard sorting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_analytics_cat2.json", "tmp/test_analytics_cat2.wal", "tmp/test_analytics_cat2_persons");
    defer cat.deinit();

    // Seed movies
    _ = try cat.addOrUpdateMovie(.{
        .id = 1,
        .library_id = 1,
        .file_path = "/path/movie1.mkv",
        .clean_name = "Movie One",
        .title = "Movie One",
        .file_size = 1000,
    });
    _ = try cat.addOrUpdateMovie(.{
        .id = 2,
        .library_id = 1,
        .file_path = "/path/movie2.mkv",
        .clean_name = "Movie Two",
        .title = "Movie Two",
        .file_size = 2000,
    });

    // Seed show and episode
    const show_id = try cat.addOrUpdateShow(.{
        .id = 10,
        .library_id = 2,
        .path = "/path/Show",
        .title = "Epic Series",
    });
    const ep_id = try cat.addOrUpdateEpisode(.{
        .id = 101,
        .show_id = show_id,
        .file_path = "/path/Show/S01E01.mkv",
        .season = 1,
        .episode = 1,
        .file_size = 500,
    });

    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_analytics_logs2.json", "tmp/test_analytics_logs2.wal");
    defer logs.deinit();

    // Alice watches Movie 1: 1 start, 5 progress (50s)
    try logs.logPlaybackEvent("alice", 1, "start", 0.0);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try logs.logPlaybackEvent("alice", 1, "progress", @floatFromInt((i + 1) * 10));
    }

    // Bob watches Movie 1: 1 start, 3 progress (30s)
    try logs.logPlaybackEvent("bob", 1, "start", 0.0);
    i = 0;
    while (i < 3) : (i += 1) {
        try logs.logPlaybackEvent("bob", 1, "progress", @floatFromInt((i + 1) * 10));
    }

    // Alice watches Movie 2: 1 start, 10 progress (100s)
    try logs.logPlaybackEvent("alice", 2, "start", 0.0);
    i = 0;
    while (i < 10) : (i += 1) {
        try logs.logPlaybackEvent("alice", 2, "progress", @floatFromInt((i + 1) * 10));
    }

    // Charlie watches Show 1 episode 1: 1 start, 8 progress (80s)
    try logs.logEpisodePlaybackEvent("charlie", ep_id, "start", 0.0);
    i = 0;
    while (i < 8) : (i += 1) {
        try logs.logEpisodePlaybackEvent("charlie", ep_id, "progress", @floatFromInt((i + 1) * 10));
    }

    var report = try computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    // Total watch seconds = 50 + 30 + 100 + 80 = 260
    try std.testing.expectEqual(@as(u64, 260), report.overview.total_watch_seconds);
    // Total plays = 1 + 1 + 1 + 1 = 4
    try std.testing.expectEqual(@as(u64, 4), report.overview.total_plays);
    // Active viewers = alice, bob, charlie = 3
    try std.testing.expectEqual(@as(u64, 3), report.overview.active_viewers);

    // Top movies: Movie 2 has 100s, Movie 1 has 80s
    try std.testing.expectEqual(@as(usize, 2), report.top_movies.len);
    try std.testing.expectEqual(@as(i64, 2), report.top_movies[0].movie_id);
    try std.testing.expectEqual(@as(u64, 100), report.top_movies[0].seconds_watched);
    try std.testing.expectEqual(@as(i64, 1), report.top_movies[1].movie_id);
    try std.testing.expectEqual(@as(u64, 80), report.top_movies[1].seconds_watched);

    // Top shows: Show 1 has 80s
    try std.testing.expectEqual(@as(usize, 1), report.top_shows.len);
    try std.testing.expectEqual(show_id, report.top_shows[0].show_id);
    try std.testing.expectEqual(@as(u64, 80), report.top_shows[0].seconds_watched);

    // Top users: Alice has 150s (50 + 100), Charlie has 80s, Bob has 30s
    try std.testing.expectEqual(@as(usize, 3), report.user_activity.len);
    try std.testing.expectEqualStrings("alice", report.user_activity[0].username);
    try std.testing.expectEqual(@as(u64, 150), report.user_activity[0].seconds_watched);
    try std.testing.expectEqualStrings("charlie", report.user_activity[1].username);
    try std.testing.expectEqual(@as(u64, 80), report.user_activity[1].seconds_watched);
    try std.testing.expectEqualStrings("bob", report.user_activity[2].username);
    try std.testing.expectEqual(@as(u64, 30), report.user_activity[2].seconds_watched);
}

test "analytics: star power and library trivia computation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_analytics_cat3.json", "tmp/test_analytics_cat3.wal", "tmp/test_analytics_cat3_persons");
    defer cat.deinit();

    // 1. Seed people
    try cat.addOrUpdatePerson(.{ .id = 1, .name = "Cillian Murphy", .known_for_department = "Acting" });
    try cat.addOrUpdatePerson(.{ .id = 2, .name = "Christopher Nolan", .known_for_department = "Directing" });
    try cat.addOrUpdatePerson(.{ .id = 3, .name = "Tom Hardy", .known_for_department = "Acting" });

    // 2. Seed movies & show
    const m1_id = try cat.addOrUpdateMovie(.{
        .id = 1,
        .library_id = 1,
        .file_path = "/path/m1.mkv",
        .clean_name = "Inception",
        .title = "Inception",
        .release_date = "2010-07-16",
    });
    const m2_id = try cat.addOrUpdateMovie(.{
        .id = 2,
        .library_id = 1,
        .file_path = "/path/m2.mkv",
        .clean_name = "Dunkirk",
        .title = "Dunkirk",
        .release_date = "2017-07-21",
    });
    const s1_id = try cat.addOrUpdateShow(.{
        .id = 10,
        .library_id = 2,
        .path = "/path/Peaky Blinders (2013)",
        .title = "Peaky Blinders (2013)",
    });
    const ep1_id = try cat.addOrUpdateEpisode(.{
        .id = 101,
        .show_id = s1_id,
        .file_path = "/path/ep1.mkv",
        .season = 1,
        .episode = 1,
    });

    // 3. Seed credits
    // Inception: Nolan directs, Cillian acts, Tom Hardy acts
    _ = try cat.addMovieCredit(.{ .id = 1, .movie_id = m1_id, .person_id = 2, .name = "Christopher Nolan", .department = "Directing", .job = "Director", .is_cast = false });
    _ = try cat.addMovieCredit(.{ .id = 2, .movie_id = m1_id, .person_id = 1, .name = "Cillian Murphy", .character = "Robert Fischer", .is_cast = true, .order = 1 });
    _ = try cat.addMovieCredit(.{ .id = 3, .movie_id = m1_id, .person_id = 3, .name = "Tom Hardy", .character = "Eames", .is_cast = true, .order = 2 });

    // Dunkirk: Nolan directs, Cillian acts, Tom Hardy acts
    _ = try cat.addMovieCredit(.{ .id = 4, .movie_id = m2_id, .person_id = 2, .name = "Christopher Nolan", .department = "Directing", .job = "Director", .is_cast = false });
    _ = try cat.addMovieCredit(.{ .id = 5, .movie_id = m2_id, .person_id = 1, .name = "Cillian Murphy", .character = "Shivering Soldier", .is_cast = true, .order = 1 });
    _ = try cat.addMovieCredit(.{ .id = 6, .movie_id = m2_id, .person_id = 3, .name = "Tom Hardy", .character = "Farrier", .is_cast = true, .order = 2 });

    // Peaky Blinders: Cillian Murphy stars, Tom Hardy guest stars
    _ = try cat.addShowCredit(.{ .id = 7, .show_id = s1_id, .person_id = 1, .name = "Cillian Murphy", .character = "Thomas Shelby", .is_cast = true, .order = 0 });
    _ = try cat.addShowCredit(.{ .id = 8, .show_id = s1_id, .person_id = 3, .name = "Tom Hardy", .character = "Alfie Solomons", .is_cast = true, .order = 1 });

    // 4. Seed playback logs: Inception (50s), Dunkirk (30s), Peaky Blinders (40s)
    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_analytics_logs3.json", "tmp/test_analytics_logs3.wal");
    defer logs.deinit();

    try logs.logPlaybackEvent("alice", m1_id, "start", 0.0);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try logs.logPlaybackEvent("alice", m1_id, "progress", @floatFromInt((i + 1) * 10));
    }
    try logs.logPlaybackEvent("alice", m2_id, "start", 0.0);
    i = 0;
    while (i < 3) : (i += 1) {
        try logs.logPlaybackEvent("alice", m2_id, "progress", @floatFromInt((i + 1) * 10));
    }
    try logs.logEpisodePlaybackEvent("alice", ep1_id, "start", 0.0);
    i = 0;
    while (i < 4) : (i += 1) {
        try logs.logEpisodePlaybackEvent("alice", ep1_id, "progress", @floatFromInt((i + 1) * 10));
    }

    var report = try computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    // 5. Verify Star Power:
    // Cillian Murphy watched in Inception (50s) + Dunkirk (30s) + Peaky (40s) = 120s
    // Christopher Nolan watched in Inception (50s) + Dunkirk (30s) = 80s
    try std.testing.expect(report.top_actors.len >= 2);
    try std.testing.expectEqualStrings("Cillian Murphy", report.top_actors[0].name);
    try std.testing.expectEqual(@as(u64, 120), report.top_actors[0].seconds_watched);
    try std.testing.expectEqual(@as(usize, 3), report.top_actors[0].titles_count);

    try std.testing.expect(report.top_directors.len >= 1);
    try std.testing.expectEqualStrings("Christopher Nolan", report.top_directors[0].name);
    try std.testing.expectEqual(@as(u64, 80), report.top_directors[0].seconds_watched);
    try std.testing.expectEqual(@as(usize, 2), report.top_directors[0].titles_count);

    // 6. Verify Trivia:
    // Ubiquitous actor: Cillian Murphy or Tom Hardy appears in 3 titles (Inception, Dunkirk, Peaky)
    try std.testing.expect(report.trivia.ubiquitous_actor != null);
    try std.testing.expect(report.trivia.ubiquitous_actor.?.title_count >= 3);

    // Title crossover: Inception & Dunkirk share 2 actors (Cillian Murphy, Tom Hardy)
    try std.testing.expect(report.trivia.crossover != null);
    try std.testing.expectEqual(@as(usize, 2), report.trivia.crossover.?.shared_actor_count);

    // Dynamic duo: collaborators found with shared_title_count >= 2
    try std.testing.expect(report.trivia.collaborators != null);
    try std.testing.expect(report.trivia.collaborators.?.shared_title_count >= 2);

    // Eras: 2010s has 100% of watch time (Inception 2010, Dunkirk 2017, Peaky 2013)
    try std.testing.expectEqual(@as(usize, 7), report.trivia.eras.len);
    for (report.trivia.eras) |era| {
        if (era.decade == 2010) {
            try std.testing.expectEqual(@as(u8, 100), era.percent);
        } else {
            try std.testing.expectEqual(@as(u8, 0), era.percent);
        }
    }
}
