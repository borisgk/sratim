const std = @import("std");
const db_mod = @import("db.zig");
const c = @import("../core/c.zig").c;

pub const ProgressInfo = struct {
    movie_id: i64,
    position: f64,
    duration: f64,
};

pub const EpisodeProgressInfo = struct {
    episode_id: i64,
    position: f64,
    duration: f64,
};

/// Initializes the logging and progress database schema.
pub fn initLogsSchema(database: *db_mod.Database) !void {
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS login_logs (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    username TEXT NOT NULL,
        \\    status TEXT NOT NULL CHECK(status IN ('success', 'failed')),
        \\    ip_address TEXT NOT NULL,
        \\    timestamp INTEGER NOT NULL
        \\);
    );
    // Check if playback_logs has movie_id
    var table_exists = false;
    var stmt_check = try database.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='playback_logs';");
    if ((try stmt_check.step()) == .row) {
        table_exists = true;
    }
    stmt_check.finalize();

    if (table_exists) {
        var has_movie_id = false;
        var stmt = try database.prepare("PRAGMA table_info(playback_logs);");
        while ((try stmt.step()) == .row) {
            const col_name = stmt.columnText(1);
            if (col_name != null and std.mem.eql(u8, col_name.?, "movie_id")) {
                has_movie_id = true;
                break;
            }
        }
        stmt.finalize();

        if (!has_movie_id) {
            _ = database.exec("DROP TABLE IF EXISTS playback_logs;") catch {};
            _ = database.exec("DROP TABLE IF EXISTS playback_progress;") catch {};
        }
    }

    try database.exec(
        \\CREATE TABLE IF NOT EXISTS playback_logs (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    username TEXT NOT NULL,
        \\    movie_id INTEGER NOT NULL,
        \\    event_type TEXT NOT NULL CHECK(event_type IN ('start', 'stop', 'seek', 'progress')),
        \\    position REAL NOT NULL,
        \\    timestamp INTEGER NOT NULL
        \\);
    );
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS playback_progress (
        \\    username TEXT NOT NULL,
        \\    movie_id INTEGER NOT NULL,
        \\    position REAL NOT NULL,
        \\    duration REAL NOT NULL,
        \\    updated_at INTEGER NOT NULL,
        \\    PRIMARY KEY(username, movie_id)
        \\);
    );
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS episode_playback_logs (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    username TEXT NOT NULL,
        \\    episode_id INTEGER NOT NULL,
        \\    event_type TEXT NOT NULL CHECK(event_type IN ('start', 'stop', 'seek', 'progress')),
        \\    position REAL NOT NULL,
        \\    timestamp INTEGER NOT NULL
        \\);
    );
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS episode_playback_progress (
        \\    username TEXT NOT NULL,
        \\    episode_id INTEGER NOT NULL,
        \\    position REAL NOT NULL,
        \\    duration REAL NOT NULL,
        \\    updated_at INTEGER NOT NULL,
        \\    PRIMARY KEY(username, episode_id)
        \\);
    );
}

/// Logs a user authentication attempt (success or failure).
pub fn logLoginAttempt(database: *db_mod.Database, username: []const u8, status: []const u8, ip_address: []const u8) !void {
    const now = c.time(null);
    var stmt = try database.prepare("INSERT INTO login_logs (username, status, ip_address, timestamp) VALUES (?1, ?2, ?3, ?4);");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindText(2, status);
    try stmt.bindText(3, ip_address);
    try stmt.bindInt64(4, now);

    _ = try stmt.step();
}

/// Logs a specific playback watch event.
pub fn logPlaybackEvent(database: *db_mod.Database, username: []const u8, movie_id: i64, event_type: []const u8, position: f64) !void {
    const now = c.time(null);
    var stmt = try database.prepare("INSERT INTO playback_logs (username, movie_id, event_type, position, timestamp) VALUES (?1, ?2, ?3, ?4, ?5);");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, movie_id);
    try stmt.bindText(3, event_type);
    
    // Convert float to double representation in SQLite
    if (c.sqlite3_bind_double(stmt.stmt, 4, position) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
    
    try stmt.bindInt64(5, now);

    _ = try stmt.step();
}

/// Saves the user's current playback position progress for a media file.
pub fn savePlaybackProgress(database: *db_mod.Database, username: []const u8, movie_id: i64, position: f64, duration: f64) !void {
    const now = c.time(null);
    var stmt = try database.prepare(
        \\INSERT INTO playback_progress (username, movie_id, position, duration, updated_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
        \\ON CONFLICT(username, movie_id) DO UPDATE SET
        \\  position = excluded.position,
        \\  duration = excluded.duration,
        \\  updated_at = excluded.updated_at;
    );
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, movie_id);

    if (c.sqlite3_bind_double(stmt.stmt, 3, position) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
    if (c.sqlite3_bind_double(stmt.stmt, 4, duration) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }

    try stmt.bindInt64(5, now);

    _ = try stmt.step();
}

/// Retrieves the user's last saved playback position for a specific media file.
/// Returns the position in seconds, or 0.0 if not found.
pub fn getPlaybackProgress(database: *db_mod.Database, username: []const u8, movie_id: i64) !f64 {
    var stmt = try database.prepare("SELECT position FROM playback_progress WHERE username = ?1 AND movie_id = ?2;");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, movie_id);

    if ((try stmt.step()) == .row) {
        return c.sqlite3_column_double(stmt.stmt, 0);
    }
    return 0.0;
}

/// Retrieves all playback progress records for a given user.
pub fn getProgressForUser(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8) ![]ProgressInfo {
    var list = std.ArrayList(ProgressInfo).empty;
    defer list.deinit(allocator);

    var stmt = try database.prepare("SELECT movie_id, position, duration FROM playback_progress WHERE username = ?1;");
    defer stmt.finalize();

    try stmt.bindText(1, username);

    while ((try stmt.step()) == .row) {
        const movie_id = stmt.columnInt64(0);
        const position = c.sqlite3_column_double(stmt.stmt, 1);
        const duration = c.sqlite3_column_double(stmt.stmt, 2);

        try list.append(allocator, .{
            .movie_id = movie_id,
            .position = position,
            .duration = duration,
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Resets the user's playback position to 0 for a media file.
pub fn resetPlaybackProgress(database: *db_mod.Database, username: []const u8, movie_id: i64) !void {
    var stmt = try database.prepare("DELETE FROM playback_progress WHERE username = ?1 AND movie_id = ?2;");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, movie_id);

    _ = try stmt.step();
}

/// Logs a specific episode playback watch event.
pub fn logEpisodePlaybackEvent(database: *db_mod.Database, username: []const u8, episode_id: i64, event_type: []const u8, position: f64) !void {
    const now = c.time(null);
    var stmt = try database.prepare("INSERT INTO episode_playback_logs (username, episode_id, event_type, position, timestamp) VALUES (?1, ?2, ?3, ?4, ?5);");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, episode_id);
    try stmt.bindText(3, event_type);
    
    if (c.sqlite3_bind_double(stmt.stmt, 4, position) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
    
    try stmt.bindInt64(5, now);

    _ = try stmt.step();
}

/// Saves the user's current playback position progress for an episode.
pub fn saveEpisodePlaybackProgress(database: *db_mod.Database, username: []const u8, episode_id: i64, position: f64, duration: f64) !void {
    const now = c.time(null);
    var stmt = try database.prepare(
        \\INSERT INTO episode_playback_progress (username, episode_id, position, duration, updated_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5)
        \\ON CONFLICT(username, episode_id) DO UPDATE SET
        \\  position = excluded.position,
        \\  duration = excluded.duration,
        \\  updated_at = excluded.updated_at;
    );
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, episode_id);

    if (c.sqlite3_bind_double(stmt.stmt, 3, position) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
    if (c.sqlite3_bind_double(stmt.stmt, 4, duration) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }

    try stmt.bindInt64(5, now);

    _ = try stmt.step();
}

/// Retrieves the user's last saved playback position for a specific episode.
pub fn getEpisodePlaybackProgress(database: *db_mod.Database, username: []const u8, episode_id: i64) !f64 {
    var stmt = try database.prepare("SELECT position FROM episode_playback_progress WHERE username = ?1 AND episode_id = ?2;");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, episode_id);

    if ((try stmt.step()) == .row) {
        return c.sqlite3_column_double(stmt.stmt, 0);
    }
    return 0.0;
}

/// Retrieves all episode playback progress records for a given user.
pub fn getEpisodeProgressForUser(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8) ![]EpisodeProgressInfo {
    var list = std.ArrayList(EpisodeProgressInfo).empty;
    defer list.deinit(allocator);

    var stmt = try database.prepare("SELECT episode_id, position, duration FROM episode_playback_progress WHERE username = ?1;");
    defer stmt.finalize();

    try stmt.bindText(1, username);

    while ((try stmt.step()) == .row) {
        const episode_id = stmt.columnInt64(0);
        const position = c.sqlite3_column_double(stmt.stmt, 1);
        const duration = c.sqlite3_column_double(stmt.stmt, 2);

        try list.append(allocator, .{
            .episode_id = episode_id,
            .position = position,
            .duration = duration,
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Resets the user's playback position to 0 for an episode.
pub fn resetEpisodePlaybackProgress(database: *db_mod.Database, username: []const u8, episode_id: i64) !void {
    var stmt = try database.prepare("DELETE FROM episode_playback_progress WHERE username = ?1 AND episode_id = ?2;");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, episode_id);

    _ = try stmt.step();
}

test "logging: test login and playback event logs" {
    const allocator = std.testing.allocator;
    
    // Open a temporary database in memory for testing
    var db = try db_mod.Database.open(":memory:");
    defer db.close();
    
    try initLogsSchema(&db);
    
    // Test login logging
    try logLoginAttempt(&db, "testuser", "success", "1.2.3.4");
    try logLoginAttempt(&db, "testuser", "failed", "1.2.3.4");
    
    // Test playback progress
    try savePlaybackProgress(&db, "testuser", 1, 42.5, 120.0);
    const progress = try getPlaybackProgress(&db, "testuser", 1);
    try std.testing.expectEqual(@as(f64, 42.5), progress);
    
    // Test library progress list
    const items = try getProgressForUser(&db, allocator, "testuser");
    defer {
        allocator.free(items);
    }
    
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].movie_id);
    try std.testing.expectEqual(@as(f64, 42.5), items[0].position);
    try std.testing.expectEqual(@as(f64, 120.0), items[0].duration);

    // Test playback progress deletion
    try resetPlaybackProgress(&db, "testuser", 1);
    const progress_after_delete = try getPlaybackProgress(&db, "testuser", 1);
    try std.testing.expectEqual(@as(f64, 0.0), progress_after_delete);
}
