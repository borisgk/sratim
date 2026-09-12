const std = @import("std");
const db_mod = @import("db.zig");

pub const AdminStats = struct {
    total_movies: i64,
    total_shows: i64,
    total_episodes: i64,
    total_other_files: i64,
    total_storage_bytes: u64,
    total_users: i64,
    total_unmatched: i64,
    total_directors: i64,
    total_actors: i64,
};

/// Formats a byte size into a human-readable string (e.g. 14.5 GB, 1.2 TB).
pub fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const kb: f64 = 1024.0;
    const mb: f64 = kb * 1024.0;
    const gb: f64 = mb * 1024.0;
    const tb: f64 = gb * 1024.0;

    const b = @as(f64, @floatFromInt(bytes));
    if (b >= tb) {
        return try std.fmt.allocPrint(allocator, "{d:.2} TB", .{b / tb});
    } else if (b >= gb) {
        return try std.fmt.allocPrint(allocator, "{d:.2} GB", .{b / gb});
    } else if (b >= mb) {
        return try std.fmt.allocPrint(allocator, "{d:.1} MB", .{b / mb});
    } else if (b >= kb) {
        return try std.fmt.allocPrint(allocator, "{d:.1} KB", .{b / kb});
    } else {
        return try std.fmt.allocPrint(allocator, "{d} B", .{bytes});
    }
}

/// Queries the storage engine for total counts and storage size of movies, shows, episodes, other files, directors, and actors.
pub fn getAdminStats(database: *db_mod.Database, allocator: std.mem.Allocator) !AdminStats {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.rwlock.lockSharedUncancelable(cat.io);
    defer cat.rwlock.unlockShared(cat.io);

    var total_movies: i64 = 0;
    var total_other_files: i64 = 0;
    var movies_size: i64 = 0;

    var m_it = cat.movies.iterator();
    while (m_it.next()) |e| {
        if (!e.value_ptr.is_present) continue;
        movies_size += e.value_ptr.file_size;
        if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
            if (lib.lib_type == .Movies) {
                total_movies += 1;
            } else if (lib.lib_type == .Other) {
                total_other_files += 1;
            }
        }
    }

    var total_shows: i64 = 0;
    var sh_it = cat.shows.iterator();
    while (sh_it.next()) |e| {
        if (e.value_ptr.is_present) total_shows += 1;
    }

    var total_episodes: i64 = 0;
    var episodes_size: i64 = 0;
    var ep_it = cat.episodes.iterator();
    while (ep_it.next()) |e| {
        if (e.value_ptr.is_present) {
            total_episodes += 1;
            episodes_size += e.value_ptr.file_size;
        }
    }

    var unmatched_count: i64 = 0;
    var un_m = cat.movies.iterator();
    while (un_m.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
            if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
                if (lib.lib_type == .Movies) unmatched_count += 1;
            }
        }
    }
    var un_sh = cat.shows.iterator();
    while (un_sh.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
            if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
                if (lib.lib_type == .Shows) unmatched_count += 1;
            }
        }
    }

    var directors_set = std.AutoHashMap(i64, void).init(allocator);
    defer directors_set.deinit();

    var actors_set = std.AutoHashMap(i64, void).init(allocator);
    defer actors_set.deinit();

    var cred_it = cat.movie_credits.iterator();
    while (cred_it.next()) |e| {
        const c = e.value_ptr;
        if (cat.movies.get(c.movie_id)) |m| {
            if (!m.is_present) continue;
        } else {
            continue;
        }

        if (c.is_cast) {
            try actors_set.put(c.person_id, {});
        }
        if (!c.is_cast and c.job != null and std.ascii.eqlIgnoreCase(c.job.?, "director")) {
            try directors_set.put(c.person_id, {});
        }
    }

    return .{
        .total_movies = total_movies,
        .total_shows = total_shows,
        .total_episodes = total_episodes,
        .total_other_files = total_other_files,
        .total_storage_bytes = @intCast(@max(0, movies_size + episodes_size)),
        .total_users = @intCast(cat.users.count()),
        .total_unmatched = unmatched_count,
        .total_directors = @intCast(directors_set.count()),
        .total_actors = @intCast(actors_set.count()),
    };
}

test "getAdminStats: counts movies, directors, and actors accurately" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const snap_path = "tmp/test_admin_stats.json";
    const wal_path = "tmp/test_admin_stats.wal";
    const persons_dir = "tmp/test_admin_stats_persons";
    defer std.Io.Dir.cwd().deleteFile(testing.io, snap_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(testing.io, wal_path) catch {};
    defer std.Io.Dir.cwd().deleteTree(testing.io, persons_dir) catch {};

    const engine = @import("../storage/engine.zig");

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

    const stats = try getAdminStats(&db, allocator);
    try testing.expectEqual(@as(i64, 2), stats.total_movies);
    try testing.expectEqual(@as(i64, 2), stats.total_directors);
    try testing.expectEqual(@as(i64, 2), stats.total_actors);
    try testing.expectEqual(@as(u64, 3000), stats.total_storage_bytes);
}

