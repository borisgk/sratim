const std = @import("std");
const db_mod = @import("db.zig");
const c = @import("../core/c.zig").c;

pub const ProgressInfo = struct {
    file_path: []const u8,
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
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS playback_logs (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    username TEXT NOT NULL,
        \\    library_id INTEGER NOT NULL,
        \\    file_path TEXT NOT NULL,
        \\    event_type TEXT NOT NULL CHECK(event_type IN ('start', 'stop', 'seek', 'progress')),
        \\    position REAL NOT NULL,
        \\    timestamp INTEGER NOT NULL
        \\);
    );
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS playback_progress (
        \\    username TEXT NOT NULL,
        \\    library_id INTEGER NOT NULL,
        \\    file_path TEXT NOT NULL,
        \\    position REAL NOT NULL,
        \\    duration REAL NOT NULL,
        \\    updated_at INTEGER NOT NULL,
        \\    PRIMARY KEY(username, library_id, file_path)
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
pub fn logPlaybackEvent(database: *db_mod.Database, username: []const u8, library_id: i64, file_path: []const u8, event_type: []const u8, position: f64) !void {
    const now = c.time(null);
    var stmt = try database.prepare("INSERT INTO playback_logs (username, library_id, file_path, event_type, position, timestamp) VALUES (?1, ?2, ?3, ?4, ?5, ?6);");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, library_id);
    try stmt.bindText(3, file_path);
    try stmt.bindText(4, event_type);
    
    // Convert float to double representation in SQLite
    if (c.sqlite3_bind_double(stmt.stmt, 5, position) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
    
    try stmt.bindInt64(6, now);

    _ = try stmt.step();
}

/// Saves the user's current playback position progress for a media file.
pub fn savePlaybackProgress(database: *db_mod.Database, username: []const u8, library_id: i64, file_path: []const u8, position: f64, duration: f64) !void {
    const now = c.time(null);
    var stmt = try database.prepare(
        \\INSERT INTO playback_progress (username, library_id, file_path, position, duration, updated_at)
        \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
        \\ON CONFLICT(username, library_id, file_path) DO UPDATE SET
        \\  position = excluded.position,
        \\  duration = excluded.duration,
        \\  updated_at = excluded.updated_at;
    );
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, library_id);
    try stmt.bindText(3, file_path);

    if (c.sqlite3_bind_double(stmt.stmt, 4, position) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
    if (c.sqlite3_bind_double(stmt.stmt, 5, duration) != c.SQLITE_OK) {
        return error.SqliteBindFailed;
    }
    
    try stmt.bindInt64(6, now);

    _ = try stmt.step();
}

/// Retrieves the saved playback position for a specific user and video file.
/// Returns 0.0 if not found.
pub fn getPlaybackProgress(database: *db_mod.Database, username: []const u8, library_id: i64, file_path: []const u8) !f64 {
    var stmt = try database.prepare("SELECT position FROM playback_progress WHERE username = ?1 AND library_id = ?2 AND file_path = ?3;");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, library_id);
    try stmt.bindText(3, file_path);

    if (try stmt.step() == .row) {
        return c.sqlite3_column_double(stmt.stmt, 0);
    }
    return 0.0;
}

/// Retrieves all playback progress records for a given user and library.
pub fn getLibraryProgressForUser(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8, library_id: i64) ![]ProgressInfo {
    var list = std.ArrayList(ProgressInfo).empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.file_path);
        }
        list.deinit(allocator);
    }

    var stmt = try database.prepare("SELECT file_path, position, duration FROM playback_progress WHERE username = ?1 AND library_id = ?2;");
    defer stmt.finalize();

    try stmt.bindText(1, username);
    try stmt.bindInt64(2, library_id);

    while (try stmt.step() == .row) {
        const file_path = stmt.columnText(0) orelse "";
        const position = c.sqlite3_column_double(stmt.stmt, 1);
        const duration = c.sqlite3_column_double(stmt.stmt, 2);

        try list.append(allocator, .{
            .file_path = try allocator.dupe(u8, file_path),
            .position = position,
            .duration = duration,
        });
    }

    return try list.toOwnedSlice(allocator);
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
    try savePlaybackProgress(&db, "testuser", 1, "movie.mkv", 42.5, 120.0);
    const progress = try getPlaybackProgress(&db, "testuser", 1, "movie.mkv");
    try std.testing.expectEqual(@as(f64, 42.5), progress);
    
    // Test library progress list
    const items = try getLibraryProgressForUser(&db, allocator, "testuser", 1);
    defer {
        for (items) |item| {
            allocator.free(item.file_path);
        }
        allocator.free(items);
    }
    
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("movie.mkv", items[0].file_path);
    try std.testing.expectEqual(@as(f64, 42.5), items[0].position);
    try std.testing.expectEqual(@as(f64, 120.0), items[0].duration);
}
