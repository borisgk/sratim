const std = @import("std");
const db_mod = @import("db.zig");
const library_mod = @import("library.zig");
const parser = @import("../utils/parser.zig");
const web_utils = @import("../web/utils.zig");

fn scanSingleLibraryInternal(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    io: std.Io,
    lib: *const library_mod.Library,
) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;

    if (lib.lib_type == .Shows) {
        var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open library path {s}: {}\n", .{ lib.path, err });
            return;
        };
        defer dir.close(io);

        var iterator = dir.iterate();
        while (iterator.next(io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const show_path = std.fs.path.join(allocator, &.{ lib.path, entry.name }) catch continue;
            defer allocator.free(show_path);

            const show_id = try cat.addOrUpdateShow(.{
                .id = 0,
                .library_id = lib.id,
                .path = entry.name,
                .title = entry.name,
                .is_present = true,
            });

            var show_dir = std.Io.Dir.cwd().openDir(io, show_path, .{ .iterate = true }) catch continue;
            defer show_dir.close(io);

            var walker = show_dir.walk(allocator) catch continue;
            defer walker.deinit();

            while (walker.next(io) catch null) |ep_entry| {
                if (ep_entry.kind == .file and web_utils.isVideoFile(ep_entry.basename)) {
                    const rel_ep_path = std.fs.path.join(allocator, &.{ entry.name, ep_entry.path }) catch continue;
                    defer allocator.free(rel_ep_path);

                    const parsed = parser.parseSeasonEpisode(ep_entry.basename);
                    const ep_stat = ep_entry.dir.statFile(io, ep_entry.basename, .{}) catch null;
                    const file_size: i64 = if (ep_stat) |st| @intCast(st.size) else 0;

                    _ = try cat.addOrUpdateEpisode(.{
                        .id = 0,
                        .show_id = show_id,
                        .file_path = rel_ep_path,
                        .season = parsed.season,
                        .episode = parsed.episode,
                        .is_present = true,
                        .file_size = file_size,
                    });
                }
            }
        }
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open library path {s}: {}\n", .{ lib.path, err });
            return;
        };
        defer dir.close(io);

        var walker = dir.walk(allocator) catch |err| {
            std.debug.print("Failed to walk library path {s}: {}\n", .{ lib.path, err });
            return;
        };
        defer walker.deinit();

        while (walker.next(io) catch null) |entry| {
            if (entry.kind == .file and web_utils.isVideoFile(entry.basename)) {
                const ext = std.fs.path.extension(entry.basename);
                const ext_idx = entry.basename.len - ext.len;
                const clean_name = entry.basename[0..ext_idx];
                const movie_stat = dir.statFile(io, entry.path, .{}) catch null;
                const file_size: i64 = if (movie_stat) |st| @intCast(st.size) else 0;

                _ = try cat.addOrUpdateMovie(.{
                    .id = 0,
                    .library_id = lib.id,
                    .file_path = entry.path,
                    .clean_name = clean_name,
                    .is_present = true,
                    .file_size = file_size,
                });
            }
        }
    }

    const current_time = std.Io.Timestamp.now(cat.io, .real).toSeconds();
    cat.updateLibraryScanTime(lib.id, current_time);
    cat.snapshot() catch {};
}

/// Rescans a single library configuration by its ID.
pub fn scanLibraryById(database: *db_mod.Database, allocator: std.mem.Allocator, io: std.Io, library_id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
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
        cat.markAllShowsAbsent(lib.id);
    } else {
        cat.markAllMoviesAbsent(lib.id);
    }

    try scanSingleLibraryInternal(database, allocator, io, &lib);
}

/// Scans all enabled libraries and populates the catalog.
pub fn scanLibraryFiles(database: *db_mod.Database, allocator: std.mem.Allocator, io: std.Io) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
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
    for (libraries) |lib| {
        if (!lib.is_enabled) continue;
        if (lib.lib_type == .Shows) {
            cat.markAllShowsAbsent(lib.id);
        } else {
            cat.markAllMoviesAbsent(lib.id);
        }
    }

    for (libraries) |lib| {
        if (!lib.is_enabled) continue;
        try scanSingleLibraryInternal(database, allocator, io, &lib);
    }
}
