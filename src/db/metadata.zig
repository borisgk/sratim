const std = @import("std");
const db_mod = @import("db.zig");
const c = @import("../core/c.zig").c;

pub const MovieMetadata = struct {
    movie_id: i64,
    library_id: i64,
    file_path: []const u8,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    release_date: ?[]const u8,
};

pub const MovieInfo = struct {
    library_id: i64,
    file_path: []const u8,
};

pub const MovieMissingMetadata = struct {
    id: i64,
    clean_name: []const u8,
};

pub fn getMovieInfoById(database: *db_mod.Database, allocator: std.mem.Allocator, movie_id: i64) !?MovieInfo {
    var stmt = try database.prepare("SELECT library_id, file_path FROM movies WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt64(1, movie_id);
    if (try stmt.step() != .row) return null;
    const library_id = stmt.columnInt64(0);
    const file_path_val = stmt.columnText(1);
    var file_path_dup: []const u8 = "";
    if (file_path_val) |fp| {
        file_path_dup = try allocator.dupe(u8, fp);
    }
    return MovieInfo{ .library_id = library_id, .file_path = file_path_dup };
}

pub fn getEpisodeInfoById(database: *db_mod.Database, allocator: std.mem.Allocator, episode_id: i64) !?MovieInfo {
    var stmt = try database.prepare(
        \\SELECT s.library_id, e.file_path 
        \\FROM episodes e 
        \\JOIN shows s ON e.show_id = s.id 
        \\WHERE e.id = ?1;
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, episode_id);
    if (try stmt.step() != .row) return null;
    const library_id = stmt.columnInt64(0);
    const file_path_val = stmt.columnText(1);
    var file_path_dup: []const u8 = "";
    if (file_path_val) |fp| {
        file_path_dup = try allocator.dupe(u8, fp);
    }
    return MovieInfo{ .library_id = library_id, .file_path = file_path_dup };
}

pub fn getMoviesMissingMetadata(database: *db_mod.Database, allocator: std.mem.Allocator) ![]MovieMissingMetadata {
    var stmt = try database.prepare(
        \\SELECT m.id, m.clean_name 
        \\FROM movies m
        \\JOIN libraries l ON m.library_id = l.id
        \\WHERE m.tmdb_id IS NULL 
        \\  AND m.is_present = 1 
        \\  AND l.type = 'Movies';
    );
    defer stmt.finalize();

    var list = std.ArrayList(MovieMissingMetadata).empty;
    defer list.deinit(allocator);

    while (try stmt.step() == .row) {
        const id = stmt.columnInt64(0);
        const clean_name_val = stmt.columnText(1);
        var clean_name: []const u8 = "";
        if (clean_name_val) |cn| {
            clean_name = try allocator.dupe(u8, cn);
        }
        try list.append(allocator, MovieMissingMetadata{
            .id = id,
            .clean_name = clean_name,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn getShowsMissingMetadata(database: *db_mod.Database, allocator: std.mem.Allocator) ![]MovieMissingMetadata {
    var stmt = try database.prepare(
        \\SELECT s.id, s.title 
        \\FROM shows s
        \\JOIN libraries l ON s.library_id = l.id
        \\WHERE s.tmdb_id IS NULL 
        \\  AND s.is_present = 1 
        \\  AND l.type = 'Shows';
    );
    defer stmt.finalize();

    var list = std.ArrayList(MovieMissingMetadata).empty;
    defer list.deinit(allocator);

    while (try stmt.step() == .row) {
        const id = stmt.columnInt64(0);
        const title_val = stmt.columnText(1);
        var clean_name: []const u8 = "";
        if (title_val) |cn| {
            clean_name = try allocator.dupe(u8, cn);
        }
        try list.append(allocator, MovieMissingMetadata{
            .id = id,
            .clean_name = clean_name,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn saveMetadataById(
    database: *db_mod.Database,
    movie_id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    release_date: ?[]const u8,
) !void {
    var stmt = try database.prepare(
        \\UPDATE movies SET tmdb_id = ?2, title = ?3, overview = ?4, poster_path = ?5, backdrop_path = ?6, release_date = ?7 WHERE id = ?1;
    );
    defer stmt.finalize();

    try stmt.bindInt64(1, movie_id);
    try stmt.bindInt64(2, tmdb_id);
    try stmt.bindText(3, title);
    if (overview) |o| try stmt.bindText(4, o) else try stmt.bindNull(4);
    if (poster_path) |p| try stmt.bindText(5, p) else try stmt.bindNull(5);
    if (backdrop_path) |b| try stmt.bindText(6, b) else try stmt.bindNull(6);
    if (release_date) |r| try stmt.bindText(7, r) else try stmt.bindNull(7);

    _ = try stmt.step();
}

pub fn saveShowMetadataById(
    database: *db_mod.Database,
    show_id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    first_air_date: ?[]const u8,
) !void {
    _ = first_air_date; // Ignore for now as it's not in the schema
    var stmt = try database.prepare(
        \\UPDATE shows SET tmdb_id = ?2, title = ?3, overview = ?4, poster_path = ?5, backdrop_path = ?6 WHERE id = ?1;
    );
    defer stmt.finalize();

    try stmt.bindInt64(1, show_id);
    try stmt.bindInt64(2, tmdb_id);
    try stmt.bindText(3, title);
    if (overview) |o| try stmt.bindText(4, o) else try stmt.bindNull(4);
    if (poster_path) |p| try stmt.bindText(5, p) else try stmt.bindNull(5);
    if (backdrop_path) |b| try stmt.bindText(6, b) else try stmt.bindNull(6);

    _ = try stmt.step();
}

pub fn getMetadataById(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    movie_id: i64,
) !?MovieMetadata {
    var stmt = try database.prepare(
        \\SELECT library_id, file_path, tmdb_id, title, overview, poster_path, backdrop_path, release_date FROM movies WHERE id = ?1 AND tmdb_id IS NOT NULL AND tmdb_id > 0;
    );
    defer stmt.finalize();

    try stmt.bindInt64(1, movie_id);

    const step_res = try stmt.step();
    if (step_res != .row) return null;

    const library_id = stmt.columnInt64(0);
    const file_path_val = stmt.columnText(1);
    var file_path: []const u8 = "";
    if (file_path_val) |fp| {
        file_path = try allocator.dupe(u8, fp);
    }
    errdefer allocator.free(file_path);

    const tmdb_id = c.sqlite3_column_int64(stmt.stmt, 2);
    
    const title_val = c.sqlite3_column_text(stmt.stmt, 3);
    const title_len = c.sqlite3_column_bytes(stmt.stmt, 3);
    const title = try allocator.dupe(u8, title_val[0..@intCast(title_len)]);
    errdefer allocator.free(title);

    var overview: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 4)) |overview_val| {
        const overview_len = c.sqlite3_column_bytes(stmt.stmt, 4);
        overview = try allocator.dupe(u8, overview_val[0..@intCast(overview_len)]);
    }
    errdefer if (overview) |o| allocator.free(o);

    var poster_path: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 5)) |poster_val| {
        const poster_len = c.sqlite3_column_bytes(stmt.stmt, 5);
        poster_path = try allocator.dupe(u8, poster_val[0..@intCast(poster_len)]);
    }
    errdefer if (poster_path) |p| allocator.free(p);

    var backdrop_path: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 6)) |backdrop_val| {
        const backdrop_len = c.sqlite3_column_bytes(stmt.stmt, 6);
        backdrop_path = try allocator.dupe(u8, backdrop_val[0..@intCast(backdrop_len)]);
    }
    errdefer if (backdrop_path) |b| allocator.free(b);

    var release_date: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 7)) |date_val| {
        const date_len = c.sqlite3_column_bytes(stmt.stmt, 7);
        release_date = try allocator.dupe(u8, date_val[0..@intCast(date_len)]);
    }

    return MovieMetadata{
        .movie_id = movie_id,
        .library_id = library_id,
        .file_path = file_path,
        .tmdb_id = tmdb_id,
        .title = title,
        .overview = overview,
        .poster_path = poster_path,
        .backdrop_path = backdrop_path,
        .release_date = release_date,
    };
}

pub fn deleteMetadataById(database: *db_mod.Database, movie_id: i64) !void {
    var stmt = try database.prepare("UPDATE movies SET tmdb_id = NULL, title = NULL, overview = NULL, poster_path = NULL, backdrop_path = NULL, release_date = NULL WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt64(1, movie_id);
    _ = try stmt.step();
}

pub fn markMetadataNotFound(database: *db_mod.Database, movie_id: i64) !void {
    var stmt = try database.prepare("UPDATE movies SET tmdb_id = 0 WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt64(1, movie_id);
    _ = try stmt.step();
}

pub fn markShowMetadataNotFound(database: *db_mod.Database, show_id: i64) !void {
    var stmt = try database.prepare("UPDATE shows SET tmdb_id = 0 WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt64(1, show_id);
    _ = try stmt.step();
}

test "metadata: save, get and delete movie metadata" {
    const allocator = std.testing.allocator;
    var db = try db_mod.Database.open(":memory:");
    defer db.close();

    try db_mod.initSchema(&db);

    _ = try db.exec("INSERT INTO libraries (name, path, type) VALUES ('Test', '/tmp/test', 'Movies')");
    _ = try db.exec("INSERT INTO movies (library_id, file_path, clean_name, is_present) VALUES (1, 'test.mp4', 'test', 1)");
    
    try saveMetadataById(&db, 1, 12345, "Test Movie", "Some overview", "/path.jpg", "/bg.jpg", "2026-07-13");
    
    const meta = (try getMetadataById(&db, allocator, 1)).?;
    defer {
        allocator.free(meta.file_path);
        allocator.free(meta.title);
        if (meta.overview) |o| allocator.free(o);
        if (meta.poster_path) |p| allocator.free(p);
        if (meta.backdrop_path) |b| allocator.free(b);
        if (meta.release_date) |r| allocator.free(r);
    }

    try std.testing.expectEqual(@as(i64, 12345), meta.tmdb_id);
    try std.testing.expectEqualStrings("Test Movie", meta.title);
    try std.testing.expectEqualStrings("test.mp4", meta.file_path);

    try deleteMetadataById(&db, 1);
    const meta_nil = try getMetadataById(&db, allocator, 1);
    try std.testing.expect(meta_nil == null);
}
