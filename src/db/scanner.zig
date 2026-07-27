const std = @import("std");
const db_mod = @import("db.zig");
const library_mod = @import("library.zig");
const parser = @import("../utils/parser.zig");
const web_utils = @import("../web/utils.zig");
const c = @import("../core/c.zig").c;

fn scanSingleLibraryInternal(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    io: std.Io,
    lib: *const library_mod.Library,
    insert_stmt: *db_mod.Statement,
    insert_show_stmt: *db_mod.Statement,
    insert_ep_stmt: *db_mod.Statement,
) !void {
    if (lib.lib_type == .Shows) {
        var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open library path {s}: {}\n", .{lib.path, err});
            return;
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
            if ((try insert_show_stmt.step()) == .row) {
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
                if (ep_entry.kind == .file and web_utils.isVideoFile(ep_entry.basename)) {
                    const rel_ep_path = std.fs.path.join(allocator, &.{entry.name, ep_entry.path}) catch continue;
                    defer allocator.free(rel_ep_path);

                    const parsed = parser.parseSeasonEpisode(ep_entry.basename);
                    const ep_stat = ep_entry.dir.statFile(io, ep_entry.basename, .{}) catch null;
                    const file_size: i64 = if (ep_stat) |st| @intCast(st.size) else 0;

                    insert_ep_stmt.reset() catch continue;
                    insert_ep_stmt.bindInt64(1, show_id) catch continue;
                    insert_ep_stmt.bindText(2, rel_ep_path) catch continue;
                    insert_ep_stmt.bindInt64(3, parsed.season) catch continue;
                    insert_ep_stmt.bindInt64(4, parsed.episode) catch continue;
                    insert_ep_stmt.bindInt64(5, file_size) catch continue;
                    _ = insert_ep_stmt.step() catch |err| {
                        std.debug.print("Failed to insert episode file {s}: {}\n", .{rel_ep_path, err});
                    };
                }
            }
        }
        
        success = true;
        try database.exec("COMMIT;");
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open library path {s}: {}\n", .{lib.path, err});
            return;
        };
        defer dir.close(io);

        var walker = dir.walk(allocator) catch |err| {
            std.debug.print("Failed to walk library path {s}: {}\n", .{lib.path, err});
            return;
        };
        defer walker.deinit();

        try database.exec("BEGIN TRANSACTION;");
        var success = false;
        defer {
            if (!success) {
                database.exec("ROLLBACK;") catch {};
            }
        }

        while (walker.next(io) catch null) |entry| {
            if (entry.kind == .file and web_utils.isVideoFile(entry.basename)) {
                const ext = std.fs.path.extension(entry.basename);
                const ext_idx = entry.basename.len - ext.len;
                const clean_name = entry.basename[0..ext_idx];
                const movie_stat = dir.statFile(io, entry.path, .{}) catch null;
                const file_size: i64 = if (movie_stat) |st| @intCast(st.size) else 0;

                insert_stmt.reset() catch continue;
                insert_stmt.bindInt64(1, lib.id) catch continue;
                insert_stmt.bindText(2, entry.path) catch continue;
                insert_stmt.bindText(3, clean_name) catch continue;
                insert_stmt.bindInt64(4, file_size) catch continue;
                _ = insert_stmt.step() catch |err| {
                    std.debug.print("Failed to insert library file {s}: {}\n", .{entry.path, err});
                };
            }
        }

        success = true;
        try database.exec("COMMIT;");
    }
    
    // Update last_scanned_at
    var update_stmt = try database.prepare("UPDATE libraries SET last_scanned_at = ?1 WHERE id = ?2;");
    defer update_stmt.finalize();
    try update_stmt.bindInt64(1, c.time(null));
    try update_stmt.bindInt64(2, lib.id);
    _ = try update_stmt.step();
}

/// Rescans a single library configuration by its ID.
pub fn scanLibraryById(database: *db_mod.Database, allocator: std.mem.Allocator, io: std.Io, library_id: i64) !void {
    const lib_opt = try library_mod.getLibraryById(database, allocator, library_id);
    if (lib_opt == null) return;
    const lib = lib_opt.?;
    defer {
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    if (!lib.is_enabled) return;

    if (lib.lib_type == .Shows) {
        var stmt_shows = try database.prepare("UPDATE shows SET is_present = 0 WHERE library_id = ?1;");
        defer stmt_shows.finalize();
        try stmt_shows.bindInt64(1, lib.id);
        _ = try stmt_shows.step();

        var stmt_eps = try database.prepare("UPDATE episodes SET is_present = 0 WHERE show_id IN (SELECT id FROM shows WHERE library_id = ?1);");
        defer stmt_eps.finalize();
        try stmt_eps.bindInt64(1, lib.id);
        _ = try stmt_eps.step();
    } else {
        var stmt = try database.prepare("UPDATE movies SET is_present = 0 WHERE library_id = ?1;");
        defer stmt.finalize();
        try stmt.bindInt64(1, lib.id);
        _ = try stmt.step();
    }

    var insert_stmt = try database.prepare(
        \\INSERT INTO movies (library_id, file_path, clean_name, is_present, file_size)
        \\VALUES (?1, ?2, ?3, 1, ?4)
        \\ON CONFLICT(library_id, file_path) DO UPDATE SET 
        \\    clean_name = excluded.clean_name,
        \\    file_size = excluded.file_size,
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
        \\INSERT INTO episodes (show_id, file_path, season, episode, is_present, file_size)
        \\VALUES (?1, ?2, ?3, ?4, 1, ?5)
        \\ON CONFLICT(show_id, file_path) DO UPDATE SET 
        \\    season = excluded.season,
        \\    episode = excluded.episode,
        \\    file_size = excluded.file_size,
        \\    is_present = 1;
    );
    defer insert_ep_stmt.finalize();

    try scanSingleLibraryInternal(database, allocator, io, &lib, &insert_stmt, &insert_show_stmt, &insert_ep_stmt);
}

/// Scans all enabled libraries and populates the library_files table.
pub fn scanLibraryFiles(database: *db_mod.Database, allocator: std.mem.Allocator, io: std.Io) !void {
    const libraries = try library_mod.getLibraries(database, allocator);
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
        \\INSERT INTO movies (library_id, file_path, clean_name, is_present, file_size)
        \\VALUES (?1, ?2, ?3, 1, ?4)
        \\ON CONFLICT(library_id, file_path) DO UPDATE SET 
        \\    clean_name = excluded.clean_name,
        \\    file_size = excluded.file_size,
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
        \\INSERT INTO episodes (show_id, file_path, season, episode, is_present, file_size)
        \\VALUES (?1, ?2, ?3, ?4, 1, ?5)
        \\ON CONFLICT(show_id, file_path) DO UPDATE SET 
        \\    season = excluded.season,
        \\    episode = excluded.episode,
        \\    file_size = excluded.file_size,
        \\    is_present = 1;
    );
    defer insert_ep_stmt.finalize();

    for (libraries) |lib| {
        if (!lib.is_enabled) continue;
        try scanSingleLibraryInternal(database, allocator, io, &lib, &insert_stmt, &insert_show_stmt, &insert_ep_stmt);
    }
}
