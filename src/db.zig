const std = @import("std");
const c = @import("c.zig").c;

/// A thin Zig wrapper around an SQLite database connection.
pub const Database = struct {
    handle: *c.sqlite3,

    /// Opens (or creates) an SQLite database at the given path.
    pub fn open(path: [:0]const u8) !Database {
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open(path.ptr, &db) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }
        var self = Database{ .handle = db.? };

        // Optimize performance & concurrency pragmas
        try self.exec("PRAGMA journal_mode=WAL;");
        try self.exec("PRAGMA synchronous=NORMAL;");
        try self.exec("PRAGMA busy_timeout=5000;");
        try self.exec("PRAGMA foreign_keys=ON;");

        return self;
    }

    /// Closes the database connection.
    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    /// Executes a simple SQL statement with no parameters and no result set.
    pub fn exec(self: *Database, sql: [:0]const u8) !void {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(self.handle, sql.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            if (errmsg) |msg| c.sqlite3_free(msg);
            return error.SqliteExecFailed;
        }
    }

    /// Prepares an SQL statement for parameterised execution.
    pub fn prepare(self: *Database, sql: [:0]const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }
        return .{ .stmt = stmt.? };
    }
};

/// Bypasses Zig compile-time pointer alignment validation for SQLITE_TRANSIENT.
fn sqliteTransient() c.sqlite3_destructor_type {
    @setRuntimeSafety(false);
    var val: usize = std.math.maxInt(usize);
    _ = &val;
    return @ptrFromInt(val);
}

/// Represents a prepared SQLite statement.
pub const Statement = struct {
    stmt: *c.sqlite3_stmt,

    /// Binds a text value to a parameter (1-indexed).
    pub fn bindText(self: *Statement, index: c_int, text: []const u8) !void {
        if (c.sqlite3_bind_text(self.stmt, index, text.ptr, @intCast(text.len), sqliteTransient()) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    /// Binds an integer value to a parameter (1-indexed).
    pub fn bindInt(self: *Statement, index: c_int, value: c_int) !void {
        if (c.sqlite3_bind_int(self.stmt, index, value) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    /// Binds an i64 value to a parameter (1-indexed).
    pub fn bindInt64(self: *Statement, index: c_int, value: i64) !void {
        if (c.sqlite3_bind_int64(self.stmt, index, value) != c.SQLITE_OK) {
            return error.SqliteBindFailed;
        }
    }

    pub const StepResult = enum { row, done };

    /// Advances the statement by one step. Returns `.row` if a result row is available.
    pub fn step(self: *Statement) !StepResult {
        const rc = c.sqlite3_step(self.stmt);
        if (rc == c.SQLITE_ROW) return .row;
        if (rc == c.SQLITE_DONE) return .done;
        return error.SqliteStepFailed;
    }

    /// Reads a text column value (0-indexed). Returns null if the column is NULL.
    pub fn columnText(self: *Statement, index: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.stmt, index);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.stmt, index);
        return @as([*]const u8, @ptrCast(ptr))[0..@intCast(len)];
    }

    /// Reads an integer column value (0-indexed).
    pub fn columnInt(self: *Statement, index: c_int) c_int {
        return c.sqlite3_column_int(self.stmt, index);
    }

    /// Reads an i64 column value (0-indexed).
    pub fn columnInt64(self: *Statement, index: c_int) i64 {
        return c.sqlite3_column_int64(self.stmt, index);
    }

    /// Resets the statement so it can be executed again with new bindings.
    pub fn reset(self: *Statement) !void {
        if (c.sqlite3_reset(self.stmt) != c.SQLITE_OK) {
            return error.SqliteResetFailed;
        }
    }

    /// Destroys the prepared statement and frees associated resources.
    pub fn finalize(self: *Statement) void {
        _ = c.sqlite3_finalize(self.stmt);
    }
};

/// Initializes the database schema (creates tables if they don't exist).
pub fn initSchema(database: *Database) !void {
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS users (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    username TEXT UNIQUE NOT NULL,
        \\    password_hash TEXT NOT NULL,
        \\    salt TEXT NOT NULL,
        \\    is_admin INTEGER NOT NULL DEFAULT 0
        \\);
    );
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS sessions (
        \\    token TEXT PRIMARY KEY,
        \\    username TEXT NOT NULL,
        \\    is_admin INTEGER NOT NULL DEFAULT 0,
        \\    created_at INTEGER NOT NULL,
        \\    expires_at INTEGER NOT NULL,
        \\    FOREIGN KEY (username) REFERENCES users(username)
        \\);
    );
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS libraries (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL,
        \\    path TEXT UNIQUE NOT NULL,
        \\    type TEXT NOT NULL CHECK(type IN ('Movies', 'Shows', 'Other')),
        \\    is_enabled INTEGER NOT NULL DEFAULT 1,
        \\    depth_limit INTEGER NOT NULL DEFAULT -1,
        \\    scan_interval INTEGER NOT NULL DEFAULT 0,
        \\    metadata_language TEXT NOT NULL DEFAULT 'en',
        \\    ignore_patterns TEXT,
        \\    include_in_dashboard INTEGER NOT NULL DEFAULT 1,
        \\    created_at INTEGER NOT NULL,
        \\    updated_at INTEGER NOT NULL,
        \\    last_scanned_at INTEGER
        \\);
    );
}
