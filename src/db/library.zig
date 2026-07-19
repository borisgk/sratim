const std = @import("std");
const db_mod = @import("db.zig");
const c = @import("../core/c.zig").c;

pub const LibraryType = enum {
    Movies,
    Shows,
    Other,

    pub fn toString(self: LibraryType) []const u8 {
        return switch (self) {
            .Movies => "Movies",
            .Shows => "Shows",
            .Other => "Other",
        };
    }

    pub fn fromString(str: []const u8) ?LibraryType {
        if (std.mem.eql(u8, str, "Movies")) return .Movies;
        if (std.mem.eql(u8, str, "Shows")) return .Shows;
        if (std.mem.eql(u8, str, "Other")) return .Other;
        return null;
    }
};

pub const Library = struct {
    id: i64,
    name: []const u8,
    path: []const u8,
    lib_type: LibraryType,
    is_enabled: bool,
    depth_limit: i32,
    scan_interval: i32,
    metadata_language: []const u8,
    ignore_patterns: ?[]const u8,
    include_in_dashboard: bool,
    created_at: i64,
    updated_at: i64,
    last_scanned_at: ?i64,
};

/// Inserts a new library folder config into the database.
pub fn addLibrary(database: *db_mod.Database, name: []const u8, path: []const u8, lib_type: LibraryType) !void {
    const now = c.time(null);

    var stmt = try database.prepare(
        \\INSERT INTO libraries (name, path, type, created_at, updated_at) 
        \\VALUES (?1, ?2, ?3, ?4, ?5);
    );
    defer stmt.finalize();

    try stmt.bindText(1, name);
    try stmt.bindText(2, path);
    try stmt.bindText(3, lib_type.toString());
    try stmt.bindInt64(4, now);
    try stmt.bindInt64(5, now);

    _ = try stmt.step();
}

/// Retrieves all libraries from the database.
pub fn getLibraries(database: *db_mod.Database, allocator: std.mem.Allocator) ![]Library {
    var list = std.ArrayList(Library).empty;
    errdefer {
        for (list.items) |lib| {
            allocator.free(lib.name);
            allocator.free(lib.path);
            allocator.free(lib.metadata_language);
            if (lib.ignore_patterns) |pat| allocator.free(pat);
        }
        list.deinit(allocator);
    }

    var stmt = try database.prepare("SELECT id, name, path, type, is_enabled, depth_limit, scan_interval, metadata_language, ignore_patterns, include_in_dashboard, created_at, updated_at, last_scanned_at FROM libraries ORDER BY name ASC;");
    defer stmt.finalize();

    while (try stmt.step() == .row) {
        const id = stmt.columnInt64(0);
        const name = stmt.columnText(1) orelse "";
        const path = stmt.columnText(2) orelse "";
        const type_str = stmt.columnText(3) orelse "Other";
        const is_enabled = stmt.columnInt(4) != 0;
        const depth_limit = stmt.columnInt(5);
        const scan_interval = stmt.columnInt(6);
        const lang = stmt.columnText(7) orelse "en";
        const pat = stmt.columnText(8);
        const dashboard = stmt.columnInt(9) != 0;
        const created = stmt.columnInt64(10);
        const updated = stmt.columnInt64(11);
        const is_null = c.sqlite3_column_type(stmt.stmt, 12) == c.SQLITE_NULL;
        const scanned_opt = if (is_null) null else stmt.columnInt64(12);

        try list.append(allocator, .{
            .id = id,
            .name = try allocator.dupe(u8, name),
            .path = try allocator.dupe(u8, path),
            .lib_type = LibraryType.fromString(type_str) orelse .Other,
            .is_enabled = is_enabled,
            .depth_limit = depth_limit,
            .scan_interval = scan_interval,
            .metadata_language = try allocator.dupe(u8, lang),
            .ignore_patterns = if (pat) |p| try allocator.dupe(u8, p) else null,
            .include_in_dashboard = dashboard,
            .created_at = created,
            .updated_at = updated,
            .last_scanned_at = scanned_opt,
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Retrieves a single library configuration by its ID.
pub fn getLibraryById(database: *db_mod.Database, allocator: std.mem.Allocator, id: i64) !?Library {
    var stmt = try database.prepare("SELECT id, name, path, type, is_enabled, depth_limit, scan_interval, metadata_language, ignore_patterns, include_in_dashboard, created_at, updated_at, last_scanned_at FROM libraries WHERE id = ?1;");
    defer stmt.finalize();

    try stmt.bindInt64(1, id);

    const result = try stmt.step();
    if (result != .row) return null;

    const name = stmt.columnText(1) orelse "";
    const path = stmt.columnText(2) orelse "";
    const type_str = stmt.columnText(3) orelse "Other";
    const is_enabled = stmt.columnInt(4) != 0;
    const depth_limit = stmt.columnInt(5);
    const scan_interval = stmt.columnInt(6);
    const lang = stmt.columnText(7) orelse "en";
    const pat = stmt.columnText(8);
    const dashboard = stmt.columnInt(9) != 0;
    const created = stmt.columnInt64(10);
    const updated = stmt.columnInt64(11);
    
    const is_null = c.sqlite3_column_type(stmt.stmt, 12) == c.SQLITE_NULL;
    const scanned = if (is_null) null else @as(i64, stmt.columnInt64(12));

    return .{
        .id = id,
        .name = try allocator.dupe(u8, name),
        .path = try allocator.dupe(u8, path),
        .lib_type = LibraryType.fromString(type_str) orelse .Other,
        .is_enabled = is_enabled,
        .depth_limit = depth_limit,
        .scan_interval = scan_interval,
        .metadata_language = try allocator.dupe(u8, lang),
        .ignore_patterns = if (pat) |p| try allocator.dupe(u8, p) else null,
        .include_in_dashboard = dashboard,
        .created_at = created,
        .updated_at = updated,
        .last_scanned_at = scanned,
    };
}

const video_extensions = [_][]const u8{ ".mkv", ".mp4", ".avi", ".ts", ".webm", ".mov" };

fn isVideoFile(basename: []const u8) bool {
    for (video_extensions) |ext| {
        if (std.mem.endsWith(u8, basename, ext)) return true;
    }
    return false;
}

/// Scans all enabled libraries and populates the library_files table.
pub fn scanLibraryFiles(database: *db_mod.Database, allocator: std.mem.Allocator, io: std.Io) !void {
    const libraries = try getLibraries(database, allocator);
    defer {
        for (libraries) |lib| {
            allocator.free(lib.name);
            allocator.free(lib.path);
            allocator.free(lib.metadata_language);
            if (lib.ignore_patterns) |pat| allocator.free(pat);
        }
        allocator.free(libraries);
    }

    // Mark all existing files as not present temporarily
    _ = database.exec("UPDATE movies SET is_present = 0;") catch {};

    // Prepare insert statement
    var insert_stmt = try database.prepare(
        \\INSERT INTO movies (library_id, file_path, clean_name, is_present)
        \\VALUES (?1, ?2, ?3, 1)
        \\ON CONFLICT(library_id, file_path) DO UPDATE SET 
        \\    clean_name = excluded.clean_name,
        \\    is_present = 1;
    );
    defer insert_stmt.finalize();

    for (libraries) |lib| {
        if (!lib.is_enabled) continue;

        var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open library path {s}: {}\n", .{lib.path, err});
            continue;
        };
        defer dir.close(io);

        var walker = dir.walk(allocator) catch |err| {
            std.debug.print("Failed to walk library path {s}: {}\n", .{lib.path, err});
            continue;
        };
        defer walker.deinit();

        // Wrap insertions in a transaction for speed
        try database.exec("BEGIN TRANSACTION;");
        var success = false;
        defer {
            if (!success) {
                database.exec("ROLLBACK;") catch {};
            }
        }

        while (walker.next(io) catch null) |entry| {
            if (entry.kind == .file and isVideoFile(entry.basename)) {
                const ext = std.fs.path.extension(entry.basename);
                const ext_idx = entry.basename.len - ext.len;
                const clean_name = entry.basename[0..ext_idx];

                insert_stmt.reset() catch continue;
                insert_stmt.bindInt64(1, lib.id) catch continue;
                insert_stmt.bindText(2, entry.path) catch continue;
                insert_stmt.bindText(3, clean_name) catch continue;
                _ = insert_stmt.step() catch |err| {
                    std.debug.print("Failed to insert library file {s}: {}\n", .{entry.path, err});
                };
            }
        }

        try database.exec("COMMIT;");
        success = true;
        
        // Update last_scanned_at
        var update_stmt = try database.prepare("UPDATE libraries SET last_scanned_at = ?1 WHERE id = ?2;");
        defer update_stmt.finalize();
        try update_stmt.bindInt64(1, c.time(null));
        try update_stmt.bindInt64(2, lib.id);
        _ = try update_stmt.step();
    }
}
