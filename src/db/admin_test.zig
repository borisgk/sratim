const std = @import("std");
const db_mod = @import("db.zig");
const admin_mod = @import("admin.zig");
const engine = @import("../storage/engine.zig");

test "getAdminStats: counts movies, directors, and actors accurately" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_admin_stats.json";
    const wal_path = "tmp/test_admin_stats.wal";
    const persons_dir = "tmp/test_admin_stats_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    var db = db_mod.Database.forCatalog(&storage);

    const lib = try storage.addLibrary("Movies", "/movies", .Movies);
    const mov1 = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib.id,
        .file_path = "/movies/Matrix.mkv",
        .clean_name = "Matrix",
        .title = "The Matrix",
        .file_size = 1000,
        .is_present = true,
    });

    const mov2 = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib.id,
        .file_path = "/movies/JohnWick.mkv",
        .clean_name = "John Wick",
        .title = "John Wick",
        .file_size = 2000,
        .is_present = true,
    });

    // Keanu Reeves (person_id 6384): Actor in Matrix and John Wick
    _ = try storage.addMovieCredit(.{
        .id = 0,
        .movie_id = mov1,
        .person_id = 6384,
        .name = "Keanu Reeves",
        .character = "Neo",
        .is_cast = true,
    });
    _ = try storage.addMovieCredit(.{
        .id = 0,
        .movie_id = mov2,
        .person_id = 6384,
        .name = "Keanu Reeves",
        .character = "John Wick",
        .is_cast = true,
    });

    // Laurence Fishburne (person_id 2975): Actor in Matrix
    _ = try storage.addMovieCredit(.{
        .id = 0,
        .movie_id = mov1,
        .person_id = 2975,
        .name = "Laurence Fishburne",
        .character = "Morpheus",
        .is_cast = true,
    });

    // Lana Wachowski (person_id 9339): Director in Matrix
    _ = try storage.addMovieCredit(.{
        .id = 0,
        .movie_id = mov1,
        .person_id = 9339,
        .name = "Lana Wachowski",
        .job = "Director",
        .department = "Directing",
        .is_cast = false,
    });

    // Chad Stahelski (person_id 40644): Director in John Wick
    _ = try storage.addMovieCredit(.{
        .id = 0,
        .movie_id = mov2,
        .person_id = 40644,
        .name = "Chad Stahelski",
        .job = "Director",
        .department = "Directing",
        .is_cast = false,
    });

    const stats = try admin_mod.getAdminStats(&db, allocator);
    try testing.expectEqual(@as(i64, 2), stats.total_movies);
    try testing.expectEqual(@as(i64, 2), stats.total_directors);
    try testing.expectEqual(@as(i64, 2), stats.total_actors);
    try testing.expectEqual(@as(u64, 3000), stats.total_storage_bytes);
}

test "library_mod: renameLibrary via Database layer updates name and snapshot" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_db_rename_lib.json";
    const wal_path = "tmp/test_db_rename_lib.wal";
    const persons_dir = "tmp/test_db_rename_lib_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    var db = db_mod.Database.forCatalog(&storage);

    const library_mod = @import("library.zig");
    try library_mod.addLibrary(&db, "Original Name", "/path/to/media", .Movies);

    const libs = try library_mod.getLibraries(&db, allocator);
    defer {
        for (libs) |l| {
            allocator.free(l.name);
            allocator.free(l.path);
            allocator.free(l.metadata_language);
            if (l.ignore_patterns) |p| allocator.free(p);
        }
        allocator.free(libs);
    }
    try testing.expectEqual(@as(usize, 1), libs.len);
    const lib_id = libs[0].id;

    // Test rename
    try library_mod.renameLibrary(&db, lib_id, "Renamed Name");

    const fetched = (try library_mod.getLibraryById(&db, allocator, lib_id)).?;
    defer {
        var f = fetched;
        f.deinit(allocator);
    }
    try testing.expectEqualStrings("Renamed Name", fetched.name);
}

test "library_mod: deleteLibrary via Database layer removes catalog items without deleting files on disk" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_db_delete_lib.json";
    const wal_path = "tmp/test_db_delete_lib.wal";
    const persons_dir = "tmp/test_db_delete_lib_persons";
    const dummy_media_dir = "tmp/test_db_delete_lib_media";
    const dummy_file_path = "tmp/test_db_delete_lib_media/movie.mp4";

    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, dummy_media_dir) catch {};

    // Create dummy media dir and file on disk
    std.Io.Dir.cwd().createDirPath(testing.io, dummy_media_dir) catch {};
    var dummy_file = try std.Io.Dir.cwd().createFile(testing.io, dummy_file_path, .{});
    dummy_file.close(testing.io);

    // Verify media file exists on disk
    _ = try std.Io.Dir.cwd().statFile(testing.io, dummy_file_path, .{});

    var storage = engine.SratimStorage.init(allocator, testing.io, snap_path, wal_path, persons_dir);
    defer storage.deinit();

    var db = db_mod.Database.forCatalog(&storage);

    const library_mod = @import("library.zig");
    try library_mod.addLibrary(&db, "Test Media", dummy_media_dir, .Movies);

    const libs = try library_mod.getLibraries(&db, allocator);
    defer {
        for (libs) |l| {
            allocator.free(l.name);
            allocator.free(l.path);
            allocator.free(l.metadata_language);
            if (l.ignore_patterns) |p| allocator.free(p);
        }
        allocator.free(libs);
    }
    try testing.expectEqual(@as(usize, 1), libs.len);
    const lib_id = libs[0].id;

    // Add movie entry to catalog
    _ = try storage.addOrUpdateMovie(.{
        .id = 0,
        .library_id = lib_id,
        .file_path = dummy_file_path,
        .clean_name = "movie",
        .title = "Movie",
        .is_present = true,
    });

    try testing.expectEqual(@as(usize, 1), storage.countMovies());

    // Delete library via DB layer
    try library_mod.deleteLibrary(&db, lib_id);

    // Verify library is deleted from catalog
    const remaining_libs = try library_mod.getLibraries(&db, allocator);
    defer {
        for (remaining_libs) |l| {
            allocator.free(l.name);
            allocator.free(l.path);
            allocator.free(l.metadata_language);
            if (l.ignore_patterns) |p| allocator.free(p);
        }
        allocator.free(remaining_libs);
    }
    try testing.expectEqual(@as(usize, 0), remaining_libs.len);
    try testing.expectEqual(@as(usize, 0), storage.countMovies());

    // CRITICAL: Verify the media file on disk was NOT deleted!
    const file_stat = try std.Io.Dir.cwd().statFile(testing.io, dummy_file_path, .{});
    try testing.expect(file_stat.kind == .file);
}

