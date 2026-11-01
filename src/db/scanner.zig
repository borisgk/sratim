const std = @import("std");
const db_mod = @import("db.zig");
const library_mod = @import("library.zig");
const parser = @import("../utils/parser.zig");
const storage = @import("../storage/engine.zig");
const web_utils = @import("../web/utils.zig");

const max_scan_depth: usize = 16;

fn recordShowEpisode(
    cat: *storage.SratimStorage,
    allocator: std.mem.Allocator,
    show_id: i64,
    show_name: []const u8,
    rel_in_show: []const u8,
    file_size: i64,
) !void {
    const rel_ep_path = try std.fs.path.join(allocator, &.{ show_name, rel_in_show });
    defer allocator.free(rel_ep_path);

    const parsed = parser.parseSeasonEpisode(rel_in_show);

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

fn scanShowDirRecursive(
    cat: *storage.SratimStorage,
    allocator: std.mem.Allocator,
    io: std.Io,
    show_id: i64,
    show_name: []const u8,
    cur_dir: std.Io.Dir,
    rel_prefix: []const u8,
    depth: usize,
) !void {
    if (depth > max_scan_depth) return;

    var it = cur_dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            std.debug.print("Warning: failed reading directory in show '{s}' ({s}): {}\n", .{ show_name, rel_prefix, err });
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const rel_in_show = if (rel_prefix.len == 0)
            allocator.dupe(u8, entry.name) catch continue
        else
            std.fs.path.join(allocator, &.{ rel_prefix, entry.name }) catch continue;
        defer allocator.free(rel_in_show);

        switch (entry.kind) {
            .directory => {
                var sub_dir = cur_dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                    std.debug.print("Warning: failed to open season/sub-directory '{s}/{s}': {}\n", .{ show_name, rel_in_show, err });
                    continue;
                };
                defer sub_dir.close(io);
                try scanShowDirRecursive(cat, allocator, io, show_id, show_name, sub_dir, rel_in_show, depth + 1);
            },
            .file => {
                if (web_utils.isVideoFile(entry.name)) {
                    const ep_stat = cur_dir.statFile(io, entry.name, .{}) catch null;
                    const file_size: i64 = if (ep_stat) |st| @intCast(st.size) else 0;
                    try recordShowEpisode(cat, allocator, show_id, show_name, rel_in_show, file_size);
                }
            },
            .sym_link, .unknown => {
                if (web_utils.isVideoFile(entry.name)) {
                    if (cur_dir.statFile(io, entry.name, .{})) |st| {
                        if (st.kind == .file) {
                            try recordShowEpisode(cat, allocator, show_id, show_name, rel_in_show, @intCast(st.size));
                            continue;
                        }
                    } else |_| {}
                }
                if (cur_dir.openDir(io, entry.name, .{ .iterate = true })) |sub_dir_val| {
                    var sub_dir = sub_dir_val;
                    defer sub_dir.close(io);
                    try scanShowDirRecursive(cat, allocator, io, show_id, show_name, sub_dir, rel_in_show, depth + 1);
                } else |_| {}
            },
            else => {},
        }
    }
}

fn recordMovieFile(
    cat: *storage.SratimStorage,
    library_id: i64,
    rel_path: []const u8,
    basename: []const u8,
    file_size: i64,
) !void {
    const ext = std.fs.path.extension(basename);
    const ext_idx = basename.len - ext.len;
    const clean_name = basename[0..ext_idx];

    _ = try cat.addOrUpdateMovie(.{
        .id = 0,
        .library_id = library_id,
        .file_path = rel_path,
        .clean_name = clean_name,
        .is_present = true,
        .file_size = file_size,
    });
}

fn scanMovieDirRecursive(
    cat: *storage.SratimStorage,
    allocator: std.mem.Allocator,
    io: std.Io,
    library_id: i64,
    cur_dir: std.Io.Dir,
    rel_prefix: []const u8,
    depth: usize,
) !void {
    if (depth > max_scan_depth) return;

    var it = cur_dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch |err| {
            std.debug.print("Warning: failed reading movie directory ({s}): {}\n", .{ rel_prefix, err });
            break;
        };
        const entry = maybe_entry orelse break;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const rel_path = if (rel_prefix.len == 0)
            allocator.dupe(u8, entry.name) catch continue
        else
            std.fs.path.join(allocator, &.{ rel_prefix, entry.name }) catch continue;
        defer allocator.free(rel_path);

        switch (entry.kind) {
            .directory => {
                var sub_dir = cur_dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                    std.debug.print("Warning: failed to open movie subdirectory '{s}': {}\n", .{ rel_path, err });
                    continue;
                };
                defer sub_dir.close(io);
                try scanMovieDirRecursive(cat, allocator, io, library_id, sub_dir, rel_path, depth + 1);
            },
            .file => {
                if (web_utils.isVideoFile(entry.name)) {
                    const movie_stat = cur_dir.statFile(io, entry.name, .{}) catch null;
                    const file_size: i64 = if (movie_stat) |st| @intCast(st.size) else 0;
                    try recordMovieFile(cat, library_id, rel_path, entry.name, file_size);
                }
            },
            .sym_link, .unknown => {
                if (web_utils.isVideoFile(entry.name)) {
                    if (cur_dir.statFile(io, entry.name, .{})) |st| {
                        if (st.kind == .file) {
                            try recordMovieFile(cat, library_id, rel_path, entry.name, @intCast(st.size));
                            continue;
                        }
                    } else |_| {}
                }
                if (cur_dir.openDir(io, entry.name, .{ .iterate = true })) |sub_dir_val| {
                    var sub_dir = sub_dir_val;
                    defer sub_dir.close(io);
                    try scanMovieDirRecursive(cat, allocator, io, library_id, sub_dir, rel_path, depth + 1);
                } else |_| {}
            },
            else => {},
        }
    }
}

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
        while (true) {
            const maybe_entry = iterator.next(io) catch |err| {
                std.debug.print("Warning: failed reading shows library directory {s}: {}\n", .{ lib.path, err });
                break;
            };
            const entry = maybe_entry orelse break;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.kind != .directory and entry.kind != .sym_link and entry.kind != .unknown) continue;

            var show_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                if (entry.kind == .directory) {
                    std.debug.print("Warning: failed to open show directory {s}/{s}: {}\n", .{ lib.path, entry.name, err });
                }
                continue;
            };
            defer show_dir.close(io);

            const show_id = try cat.addOrUpdateShow(.{
                .id = 0,
                .library_id = lib.id,
                .path = entry.name,
                .title = entry.name,
                .is_present = true,
            });

            try scanShowDirRecursive(cat, allocator, io, show_id, entry.name, show_dir, "", 0);
        }
    } else {
        var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
            std.debug.print("Failed to open library path {s}: {}\n", .{ lib.path, err });
            return;
        };
        defer dir.close(io);

        try scanMovieDirRecursive(cat, allocator, io, lib.id, dir, "", 0);
    }

    const current_time = std.Io.Timestamp.now(cat.io, .real).toSeconds();
    cat.updateLibraryScanTime(lib.id, current_time);
    cat.snapshot() catch |err| {
        std.debug.print("Warning: failed to write catalog snapshot after scanning library {s}: {}\n", .{ lib.path, err });
    };
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
