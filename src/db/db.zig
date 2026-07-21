const std = @import("std");
const c = @import("../core/c.zig").c;

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

    /// Binds NULL to a parameter (1-indexed).
    pub fn bindNull(self: *Statement, index: c_int) !void {
        if (c.sqlite3_bind_null(self.stmt, index) != c.SQLITE_OK) {
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
    var table_exists = false;
    var stmt_check = try database.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='movies';");
    if ((try stmt_check.step()) == .row) {
        table_exists = true;
    }
    stmt_check.finalize();

    if (table_exists) {
        var has_id_col = false;
        var stmt_info = try database.prepare("PRAGMA table_info(movies);");
        while ((try stmt_info.step()) == .row) {
            const col_name = stmt_info.columnText(1);
            if (col_name != null and std.mem.eql(u8, col_name.?, "id")) {
                has_id_col = true;
                break;
            }
        }
        stmt_info.finalize();

        if (!has_id_col) {
            _ = database.exec(
                \\BEGIN TRANSACTION;
                \\ALTER TABLE movies RENAME TO movies_old;
                \\CREATE TABLE movies (
                \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\    library_id INTEGER NOT NULL,
                \\    file_path TEXT NOT NULL,
                \\    clean_name TEXT NOT NULL,
                \\    is_present INTEGER NOT NULL DEFAULT 1,
                \\    tmdb_id INTEGER,
                \\    title TEXT,
                \\    overview TEXT,
                \\    poster_path TEXT,
                \\    backdrop_path TEXT,
                \\    release_date TEXT,
                \\    UNIQUE(library_id, file_path)
                \\);
                \\INSERT INTO movies (library_id, file_path, clean_name, is_present, tmdb_id, title, overview, poster_path, backdrop_path, release_date)
                \\SELECT library_id, file_path, clean_name, is_present, tmdb_id, title, overview, poster_path, backdrop_path, release_date FROM movies_old;
                \\DROP TABLE movies_old;
                \\COMMIT;
            ) catch {};
        }
    } else {
        try database.exec(
            \\CREATE TABLE movies (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    library_id INTEGER NOT NULL,
            \\    file_path TEXT NOT NULL,
            \\    clean_name TEXT NOT NULL,
            \\    is_present INTEGER NOT NULL DEFAULT 1,
            \\    tmdb_id INTEGER,
            \\    title TEXT,
            \\    overview TEXT,
            \\    poster_path TEXT,
            \\    backdrop_path TEXT,
            \\    release_date TEXT,
            \\    UNIQUE(library_id, file_path)
            \\);
        );
    }
    
    try database.exec(
        \\CREATE TABLE IF NOT EXISTS shows (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    library_id INTEGER NOT NULL,
        \\    path TEXT NOT NULL,
        \\    title TEXT NOT NULL,
        \\    is_present INTEGER NOT NULL DEFAULT 1,
        \\    tmdb_id INTEGER,
        \\    overview TEXT,
        \\    poster_path TEXT,
        \\    backdrop_path TEXT,
        \\    UNIQUE(library_id, path)
        \\);
    );

    try database.exec(
        \\CREATE TABLE IF NOT EXISTS episodes (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    show_id INTEGER NOT NULL,
        \\    file_path TEXT NOT NULL,
        \\    season INTEGER NOT NULL DEFAULT 0,
        \\    episode INTEGER NOT NULL DEFAULT 0,
        \\    is_present INTEGER NOT NULL DEFAULT 1,
        \\    tmdb_id INTEGER,
        \\    title TEXT,
        \\    overview TEXT,
        \\    still_path TEXT,
        \\    UNIQUE(show_id, file_path)
        \\);
    );

    // Migrations to add missing columns to existing episodes table
    _ = database.exec("ALTER TABLE episodes ADD COLUMN tmdb_id INTEGER;") catch {};
    _ = database.exec("ALTER TABLE episodes ADD COLUMN title TEXT;") catch {};
    _ = database.exec("ALTER TABLE episodes ADD COLUMN overview TEXT;") catch {};
    _ = database.exec("ALTER TABLE episodes ADD COLUMN still_path TEXT;") catch {};

    // Migration logic from old tables
    // We ignore errors since this is just for safe transition, and old tables might not exist
    _ = database.exec(
        \\INSERT OR IGNORE INTO movies (library_id, file_path, clean_name, is_present, tmdb_id, title, overview, poster_path, backdrop_path, release_date)
        \\SELECT library_id, file_path, '', 1, tmdb_id, title, overview, poster_path, backdrop_path, release_date 
        \\FROM movie_metadata;
    ) catch {};
    
    _ = database.exec("DROP TABLE IF EXISTS movie_metadata;") catch {};
    _ = database.exec("DROP TABLE IF EXISTS library_files;") catch {};
}
