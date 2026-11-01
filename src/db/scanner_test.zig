const std = @import("std");
const db_mod = @import("db.zig");
const scanner = @import("scanner.zig");
const engine = @import("../storage/engine.zig");

fn writeDummyFile(io: std.Io, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_path| {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
    }
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

test "scanLibraryById discovers newly added season of existing show across naming formats" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_scanner_shows.json";
    const wal_path = "tmp/test_scanner_shows.wal";
    const persons_dir = "tmp/test_scanner_shows_persons";
    const lib_dir = "tmp/test_scanner_shows_lib";

    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, lib_dir) catch {};

    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 01/House.S01E01.mkv", "ep1");
    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 01/House.S01E02.mkv", "ep2");

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    var db = db_mod.Database.forCatalog(&storage);
    const lib = try storage.addLibrary("TV Shows", lib_dir, .Shows);

    // Initial scan (Season 1 only)
    try scanner.scanLibraryById(&db, allocator, testing.io, lib.id);

    const shows_initial = try storage.getShowsByLibrary(allocator, lib.id);
    defer {
        for (shows_initial) |*s| s.deinit(allocator);
        allocator.free(shows_initial);
    }
    try testing.expectEqual(@as(usize, 1), shows_initial.len);
    const show_id = shows_initial[0].id;

    // Simulate TMDB metadata enrichment on the existing show
    _ = try storage.addOrUpdateShow(.{
        .id = show_id,
        .library_id = lib.id,
        .path = "House",
        .title = "House M.D.",
        .tmdb_id = 1408,
        .is_present = true,
    });

    // Now add Season 02 and Season 03 with varied naming conventions + hidden AppleDouble file
    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 02/01 - Acceptance.mkv", "s2e1");
    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 02/E02 - Autopsy.mkv", "s2e2");
    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 02/._01 - Acceptance.mkv", "appledouble");
    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 03/Доктор Хаус 03-01.mkv", "s3e1");
    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 03/House.S03.E02.mkv", "s3e2");

    // Rescan library
    try scanner.scanLibraryById(&db, allocator, testing.io, lib.id);

    const show_after = (try storage.getShowById(allocator, show_id)).?;
    defer {
        var s = show_after;
        s.deinit(allocator);
    }
    try testing.expectEqual(@as(?i64, 1408), show_after.tmdb_id);
    try testing.expectEqualStrings("House M.D.", show_after.title);
    try testing.expect(show_after.is_present);

    const episodes = try storage.getEpisodesByShow(allocator, show_id);
    defer {
        for (episodes) |*ep| ep.deinit(allocator);
        allocator.free(episodes);
    }

    // Should have 6 valid episodes (2 in S1, 2 in S2, 2 in S3) and skip ._01 - Acceptance.mkv
    try testing.expectEqual(@as(usize, 6), episodes.len);

    var found_s1e1 = false;
    var found_s1e2 = false;
    var found_s2e1 = false;
    var found_s2e2 = false;
    var found_s3e1 = false;
    var found_s3e2 = false;

    for (episodes) |ep| {
        if (ep.season == 1 and ep.episode == 1) found_s1e1 = true;
        if (ep.season == 1 and ep.episode == 2) found_s1e2 = true;
        if (ep.season == 2 and ep.episode == 1) found_s2e1 = true;
        if (ep.season == 2 and ep.episode == 2) found_s2e2 = true;
        if (ep.season == 3 and ep.episode == 1) found_s3e1 = true;
        if (ep.season == 3 and ep.episode == 2) found_s3e2 = true;
    }

    try testing.expect(found_s1e1);
    try testing.expect(found_s1e2);
    try testing.expect(found_s2e1);
    try testing.expect(found_s2e2);
    try testing.expect(found_s3e1);
    try testing.expect(found_s3e2);
}

test "rescanning resets stale tmdb_id when episode season/episode numbers are repaired" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_scanner_repair.json";
    const wal_path = "tmp/test_scanner_repair.wal";
    const persons_dir = "tmp/test_scanner_repair_persons";
    const lib_dir = "tmp/test_scanner_repair_lib";

    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, lib_dir) catch {};

    try writeDummyFile(testing.io, lib_dir ++ "/House/Season 03/Доктор Хаус 03-01.mkv", "s3e1");

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    var db = db_mod.Database.forCatalog(&storage);
    const lib = try storage.addLibrary("TV Shows", lib_dir, .Shows);

    const show_id = try storage.addOrUpdateShow(.{
        .id = 0,
        .library_id = lib.id,
        .path = "House",
        .title = "House",
        .tmdb_id = 1408,
        .is_present = true,
    });

    // Pre-insert episode as previously mis-parsed (season 0, episode 0, tmdb_id = 0)
    const ep_id = try storage.addOrUpdateEpisode(.{
        .id = 0,
        .show_id = show_id,
        .file_path = "House/Season 03/Доктор Хаус 03-01.mkv",
        .season = 0,
        .episode = 0,
        .tmdb_id = 0,
        .is_present = true,
        .file_size = 4,
    });

    // Rescan library; scanner now parses Season 3 Episode 1
    try scanner.scanLibraryById(&db, allocator, testing.io, lib.id);

    const ep_after = (try storage.getEpisodeById(allocator, ep_id)).?;
    defer {
        var e = ep_after;
        e.deinit(allocator);
    }

    try testing.expectEqual(@as(i32, 3), ep_after.season);
    try testing.expectEqual(@as(i32, 1), ep_after.episode);
    try testing.expectEqual(@as(?i64, null), ep_after.tmdb_id);
}
