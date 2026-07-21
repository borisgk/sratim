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

pub fn parseSeasonEpisode(filename: []const u8) struct { season: i32, episode: i32 } {
    var season: i32 = 0;
    var episode: i32 = 0;
    
    for (0..filename.len) |i| {
        if (filename[i] == 'S' or filename[i] == 's') {
            var s_end = i + 1;
            while (s_end < filename.len and std.ascii.isDigit(filename[s_end])) {
                s_end += 1;
            }
            if (s_end > i + 1) {
                if (s_end < filename.len and (filename[s_end] == 'E' or filename[s_end] == 'e')) {
                    var e_end = s_end + 1;
                    while (e_end < filename.len and std.ascii.isDigit(filename[e_end])) {
                        e_end += 1;
                    }
                    if (e_end > s_end + 1) {
                        season = std.fmt.parseInt(i32, filename[i + 1 .. s_end], 10) catch 0;
                        episode = std.fmt.parseInt(i32, filename[s_end + 1 .. e_end], 10) catch 0;
                        return .{ .season = season, .episode = episode };
                    }
                }
            }
        }
    }
    
    for (0..filename.len) |i| {
        if (filename[i] == 'x' or filename[i] == 'X') {
            var s_start = i;
            while (s_start > 0 and std.ascii.isDigit(filename[s_start - 1])) {
                s_start -= 1;
            }
            if (s_start < i) {
                var e_end = i + 1;
                while (e_end < filename.len and std.ascii.isDigit(filename[e_end])) {
                    e_end += 1;
                }
                if (e_end > i + 1) {
                    season = std.fmt.parseInt(i32, filename[s_start .. i], 10) catch 0;
                    episode = std.fmt.parseInt(i32, filename[i + 1 .. e_end], 10) catch 0;
                    return .{ .season = season, .episode = episode };
                }
            }
        }
    }
    
    return .{ .season = 0, .episode = 0 };
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
    _ = database.exec("UPDATE shows SET is_present = 0;") catch {};
    _ = database.exec("UPDATE episodes SET is_present = 0;") catch {};

    // Prepare insert statements
    var insert_stmt = try database.prepare(
        \\INSERT INTO movies (library_id, file_path, clean_name, is_present)
        \\VALUES (?1, ?2, ?3, 1)
        \\ON CONFLICT(library_id, file_path) DO UPDATE SET 
        \\    clean_name = excluded.clean_name,
        \\    is_present = 1;
    );
    defer insert_stmt.finalize();

    var insert_show_stmt = try database.prepare(
        \\INSERT INTO shows (library_id, path, title, is_present)
        \\VALUES (?1, ?2, ?3, 1)
        \\ON CONFLICT(library_id, path) DO UPDATE SET 
        \\    title = excluded.title,
        \\    is_present = 1
        \\RETURNING id;
    );
    defer insert_show_stmt.finalize();

    var insert_ep_stmt = try database.prepare(
        \\INSERT INTO episodes (show_id, file_path, season, episode, is_present)
        \\VALUES (?1, ?2, ?3, ?4, 1)
        \\ON CONFLICT(show_id, file_path) DO UPDATE SET 
        \\    season = excluded.season,
        \\    episode = excluded.episode,
        \\    is_present = 1;
    );
    defer insert_ep_stmt.finalize();

    for (libraries) |lib| {
        if (!lib.is_enabled) continue;

        if (lib.lib_type == .Shows) {
            var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
                std.debug.print("Failed to open library path {s}: {}\n", .{lib.path, err});
                continue;
            };
            defer dir.close(io);

            try database.exec("BEGIN TRANSACTION;");
            var success = false;
            defer {
                if (!success) {
                    database.exec("ROLLBACK;") catch {};
                }
            }

            var iterator = dir.iterate();
            while (iterator.next(io) catch null) |entry| {
                if (entry.kind != .directory) continue;

                const show_path = std.fs.path.join(allocator, &.{lib.path, entry.name}) catch continue;
                defer allocator.free(show_path);

                insert_show_stmt.reset() catch continue;
                insert_show_stmt.bindInt64(1, lib.id) catch continue;
                insert_show_stmt.bindText(2, entry.name) catch continue;
                insert_show_stmt.bindText(3, entry.name) catch continue;

                var show_id: i64 = 0;
                if (insert_show_stmt.step() catch continue == .row) {
                    show_id = insert_show_stmt.columnInt64(0);
                    insert_show_stmt.reset() catch {};
                } else {
                    continue;
                }

                var show_dir = std.Io.Dir.cwd().openDir(io, show_path, .{ .iterate = true }) catch continue;
                defer show_dir.close(io);

                var walker = show_dir.walk(allocator) catch continue;
                defer walker.deinit();

                while (walker.next(io) catch null) |ep_entry| {
                    if (ep_entry.kind == .file and isVideoFile(ep_entry.basename)) {
                        const rel_ep_path = std.fs.path.join(allocator, &.{entry.name, ep_entry.path}) catch continue;
                        defer allocator.free(rel_ep_path);

                        const parsed = parseSeasonEpisode(ep_entry.basename);

                        insert_ep_stmt.reset() catch continue;
                        insert_ep_stmt.bindInt64(1, show_id) catch continue;
                        insert_ep_stmt.bindText(2, rel_ep_path) catch continue;
                        insert_ep_stmt.bindInt64(3, parsed.season) catch continue;
                        insert_ep_stmt.bindInt64(4, parsed.episode) catch continue;
                        _ = insert_ep_stmt.step() catch continue;
                    }
                }
            }
            
            try database.exec("COMMIT;");
            success = true;
        } else {
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
        }
        
        // Update last_scanned_at
        var update_stmt = try database.prepare("UPDATE libraries SET last_scanned_at = ?1 WHERE id = ?2;");
        defer update_stmt.finalize();
        try update_stmt.bindInt64(1, c.time(null));
        try update_stmt.bindInt64(2, lib.id);
        _ = try update_stmt.step();
    }
}
