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
