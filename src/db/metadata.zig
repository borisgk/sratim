const std = @import("std");
const db_mod = @import("db.zig");
const c = @import("../core/c.zig").c;

pub const MovieMetadata = struct {
    library_id: i64,
    file_path: []const u8,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    release_date: ?[]const u8,
};

pub fn saveMetadata(
    database: *db_mod.Database,
    library_id: i64,
    file_path: []const u8,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    release_date: ?[]const u8,
) !void {
    var stmt = try database.prepare(
        \\UPDATE movies SET tmdb_id = ?3, title = ?4, overview = ?5, poster_path = ?6, backdrop_path = ?7, release_date = ?8 WHERE library_id = ?1 AND file_path = ?2;
    );
    defer stmt.finalize();

    try stmt.bindInt64(1, library_id);
    try stmt.bindText(2, file_path);
    try stmt.bindInt64(3, tmdb_id);
    try stmt.bindText(4, title);
    if (overview) |o| try stmt.bindText(5, o) else try stmt.bindNull(5);
    if (poster_path) |p| try stmt.bindText(6, p) else try stmt.bindNull(6);
    if (backdrop_path) |b| try stmt.bindText(7, b) else try stmt.bindNull(7);
    if (release_date) |r| try stmt.bindText(8, r) else try stmt.bindNull(8);

    _ = try stmt.step();
}

pub fn getMetadata(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    library_id: i64,
    file_path: []const u8,
) !?MovieMetadata {
    var stmt = try database.prepare(
        \\SELECT tmdb_id, title, overview, poster_path, backdrop_path, release_date FROM movies WHERE library_id = ?1 AND file_path = ?2 AND tmdb_id IS NOT NULL;
    );
    defer stmt.finalize();

    try stmt.bindInt64(1, library_id);
    try stmt.bindText(2, file_path);

    const step_res = try stmt.step();
    if (step_res != .row) return null;

    const tmdb_id = c.sqlite3_column_int64(stmt.stmt, 0);
    
    const title_val = c.sqlite3_column_text(stmt.stmt, 1);
    const title_len = c.sqlite3_column_bytes(stmt.stmt, 1);
    const title = try allocator.dupe(u8, title_val[0..@intCast(title_len)]);
    errdefer allocator.free(title);

    var overview: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 2)) |overview_val| {
        const overview_len = c.sqlite3_column_bytes(stmt.stmt, 2);
        overview = try allocator.dupe(u8, overview_val[0..@intCast(overview_len)]);
    }
    errdefer if (overview) |o| allocator.free(o);

    var poster_path: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 3)) |poster_val| {
        const poster_len = c.sqlite3_column_bytes(stmt.stmt, 3);
        poster_path = try allocator.dupe(u8, poster_val[0..@intCast(poster_len)]);
    }
    errdefer if (poster_path) |p| allocator.free(p);

    var backdrop_path: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 4)) |backdrop_val| {
        const backdrop_len = c.sqlite3_column_bytes(stmt.stmt, 4);
        backdrop_path = try allocator.dupe(u8, backdrop_val[0..@intCast(backdrop_len)]);
    }
    errdefer if (backdrop_path) |b| allocator.free(b);

    var release_date: ?[]const u8 = null;
    if (c.sqlite3_column_text(stmt.stmt, 5)) |date_val| {
        const date_len = c.sqlite3_column_bytes(stmt.stmt, 5);
        release_date = try allocator.dupe(u8, date_val[0..@intCast(date_len)]);
    }

    return MovieMetadata{
        .library_id = library_id,
        .file_path = try allocator.dupe(u8, file_path),
        .tmdb_id = tmdb_id,
        .title = title,
        .overview = overview,
        .poster_path = poster_path,
        .backdrop_path = backdrop_path,
        .release_date = release_date,
    };
}

pub fn deleteMetadata(database: *db_mod.Database, library_id: i64, file_path: []const u8) !void {
    var stmt = try database.prepare("UPDATE movies SET tmdb_id = NULL, title = NULL, overview = NULL, poster_path = NULL, backdrop_path = NULL, release_date = NULL WHERE library_id = ?1 AND file_path = ?2;");
    defer stmt.finalize();
    try stmt.bindInt64(1, library_id);
    try stmt.bindText(2, file_path);
    _ = try stmt.step();
}

test "metadata: save, get and delete movie metadata" {
    const allocator = std.testing.allocator;
    var db = try db_mod.Database.open(":memory:");
    defer db.close();

    try db_mod.initSchema(&db);

    try saveMetadata(&db, 1, "test.mp4", 12345, "Test Movie", "Some overview", "/path.jpg", "/bg.jpg", "2026-07-13");
    
    const meta = (try getMetadata(&db, allocator, 1, "test.mp4")).?;
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
    try std.testing.expectEqualStrings("Some overview", meta.overview.?);
    try std.testing.expectEqualStrings("/path.jpg", meta.poster_path.?);
    try std.testing.expectEqualStrings("/bg.jpg", meta.backdrop_path.?);
    try std.testing.expectEqualStrings("2026-07-13", meta.release_date.?);

    try deleteMetadata(&db, 1, "test.mp4");
    const meta_nil = try getMetadata(&db, allocator, 1, "test.mp4");
    try std.testing.expect(meta_nil == null);
}
