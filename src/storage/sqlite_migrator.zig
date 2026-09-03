const std = @import("std");
const c = @import("../core/c.zig").c;
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const logs_engine = @import("logs_engine.zig");

pub fn migrateIfNeeded(
    allocator: std.mem.Allocator,
    io: std.Io,
    storage: *engine.SratimStorage,
    logs_storage: *logs_engine.LogsStorage,
    db_path: []const u8,
    logs_db_path: []const u8,
) !void {
    // 1. Check if sratim.json exists
    var needs_catalog_migration = false;
    if (std.Io.Dir.cwd().openFile(io, storage.file_path, .{ .mode = .read_only })) |f| {
        f.close(io);
    } else |_| {
        // sratim.json does not exist. Check if sratim.db exists.
        if (std.Io.Dir.cwd().openFile(io, db_path, .{ .mode = .read_only })) |f| {
            f.close(io);
            needs_catalog_migration = true;
        } else |_| {}
    }

    if (needs_catalog_migration) {
        std.debug.print("[Storage] Migrating existing SQLite catalog '{s}' to pure-Zig '{s}'...\n", .{ db_path, storage.file_path });
        try migrateCatalog(allocator, io, storage, db_path);
        try storage.snapshot();
        std.debug.print("[Storage] Successfully migrated catalog to '{s}'. Renaming old SQLite database...\n", .{storage.file_path});

        // Rename old sratim.db to sratim.db.migrated
        const backup_path = try std.fmt.allocPrint(allocator, "{s}.migrated", .{db_path});
        defer allocator.free(backup_path);
        std.Io.Dir.cwd().rename(db_path, std.Io.Dir.cwd(), backup_path, io) catch {};
    }

    // 2. Check if logs.json exists
    var needs_logs_migration = false;
    if (std.Io.Dir.cwd().openFile(io, logs_storage.file_path, .{ .mode = .read_only })) |f| {
        f.close(io);
    } else |_| {
        if (std.Io.Dir.cwd().openFile(io, logs_db_path, .{ .mode = .read_only })) |f| {
            f.close(io);
            needs_logs_migration = true;
        } else |_| {}
    }

    if (needs_logs_migration) {
        std.debug.print("[Storage] Migrating existing SQLite logs '{s}' to pure-Zig '{s}'...\n", .{ logs_db_path, logs_storage.file_path });
        try migrateLogs(allocator, io, logs_storage, logs_db_path);
        try logs_storage.snapshot();
        std.debug.print("[Storage] Successfully migrated logs to '{s}'. Renaming old SQLite database...\n", .{logs_storage.file_path});

        const backup_path = try std.fmt.allocPrint(allocator, "{s}.migrated", .{logs_db_path});
        defer allocator.free(backup_path);
        std.Io.Dir.cwd().rename(logs_db_path, std.Io.Dir.cwd(), backup_path, io) catch {};
    }
}

fn colText(stmt: ?*c.sqlite3_stmt, col: c_int) ?[]const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    if (ptr == null) return null;
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return ptr[0..len];
}

fn migrateCatalog(allocator: std.mem.Allocator, io: std.Io, storage: *engine.SratimStorage, db_path: []const u8) !void {
    _ = io;
    const z_path = try allocator.dupeZ(u8, db_path);
    defer allocator.free(z_path);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(z_path.ptr, &db) != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return error.SqliteOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    // Users
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, username, password_hash, salt, is_admin FROM users;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const uname = colText(stmt, 1) orelse continue;
                const pass = colText(stmt, 2) orelse "";
                const salt = colText(stmt, 3) orelse "";
                const is_admin = c.sqlite3_column_int(stmt, 4) != 0;

                const u = schema.User{
                    .id = id,
                    .username = try storage.allocator.dupe(u8, uname),
                    .password_hash = try storage.allocator.dupe(u8, pass),
                    .salt = try storage.allocator.dupe(u8, salt),
                    .is_admin = is_admin,
                };
                try storage.users.put(u.username, u);
                if (id >= storage.next_user_id) storage.next_user_id = id + 1;
            }
        }
    }

    // Sessions
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT token, username, is_admin, created_at, expires_at FROM sessions;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const tok = colText(stmt, 0) orelse continue;
                const uname = colText(stmt, 1) orelse "";
                const is_admin = c.sqlite3_column_int(stmt, 2) != 0;
                const created = c.sqlite3_column_int64(stmt, 3);
                const expires = c.sqlite3_column_int64(stmt, 4);

                const s = schema.Session{
                    .token = try storage.allocator.dupe(u8, tok),
                    .username = try storage.allocator.dupe(u8, uname),
                    .is_admin = is_admin,
                    .created_at = created,
                    .expires_at = expires,
                };
                try storage.sessions.put(s.token, s);
            }
        }
    }

    // Libraries
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, name, path, type, is_enabled, depth_limit, scan_interval, metadata_language, ignore_patterns, include_in_dashboard, created_at, updated_at, last_scanned_at FROM libraries;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const name = colText(stmt, 1) orelse "";
                const path = colText(stmt, 2) orelse "";
                const type_str = colText(stmt, 3) orelse "Other";
                const is_enabled = c.sqlite3_column_int(stmt, 4) != 0;
                const depth_limit = c.sqlite3_column_int(stmt, 5);
                const scan_interval = c.sqlite3_column_int(stmt, 6);
                const lang = colText(stmt, 7) orelse "en";
                const pat = colText(stmt, 8);
                const dash = c.sqlite3_column_int(stmt, 9) != 0;
                const created = c.sqlite3_column_int64(stmt, 10);
                const updated = c.sqlite3_column_int64(stmt, 11);
                const is_null = c.sqlite3_column_type(stmt, 12) == c.SQLITE_NULL;
                const scanned: ?i64 = if (is_null) null else c.sqlite3_column_int64(stmt, 12);

                const lib = schema.Library{
                    .id = id,
                    .name = try storage.allocator.dupe(u8, name),
                    .path = try storage.allocator.dupe(u8, path),
                    .lib_type = schema.LibraryType.fromString(type_str) orelse .Other,
                    .is_enabled = is_enabled,
                    .depth_limit = depth_limit,
                    .scan_interval = scan_interval,
                    .metadata_language = try storage.allocator.dupe(u8, lang),
                    .ignore_patterns = if (pat) |p| try storage.allocator.dupe(u8, p) else null,
                    .include_in_dashboard = dash,
                    .created_at = created,
                    .updated_at = updated,
                    .last_scanned_at = scanned,
                };
                try storage.libraries.put(id, lib);
                if (id >= storage.next_library_id) storage.next_library_id = id + 1;
            }
        }
    }

    // Movies
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, library_id, file_path, clean_name, is_present, tmdb_id, title, overview, poster_path, backdrop_path, release_date, file_size FROM movies;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const lib_id = c.sqlite3_column_int64(stmt, 1);
                const file_path = colText(stmt, 2) orelse "";
                const clean_name = colText(stmt, 3) orelse "";
                const is_present = c.sqlite3_column_int(stmt, 4) != 0;
                const tmdb_id: ?i64 = if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 5);
                const title = colText(stmt, 6);
                const overview = colText(stmt, 7);
                const poster = colText(stmt, 8);
                const backdrop = colText(stmt, 9);
                const rdate = colText(stmt, 10);
                const fsize = c.sqlite3_column_int64(stmt, 11);

                const m = schema.Movie{
                    .id = id,
                    .library_id = lib_id,
                    .file_path = try storage.allocator.dupe(u8, file_path),
                    .clean_name = try storage.allocator.dupe(u8, clean_name),
                    .is_present = is_present,
                    .tmdb_id = tmdb_id,
                    .title = if (title) |t| try storage.allocator.dupe(u8, t) else null,
                    .overview = if (overview) |o| try storage.allocator.dupe(u8, o) else null,
                    .poster_path = if (poster) |p| try storage.allocator.dupe(u8, p) else null,
                    .backdrop_path = if (backdrop) |b| try storage.allocator.dupe(u8, b) else null,
                    .release_date = if (rdate) |r| try storage.allocator.dupe(u8, r) else null,
                    .file_size = fsize,
                };
                try storage.movies.put(id, m);
                if (id >= storage.next_movie_id) storage.next_movie_id = id + 1;
            }
        }
    }

    // Shows
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, library_id, path, title, is_present, tmdb_id, overview, poster_path, backdrop_path FROM shows;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const lib_id = c.sqlite3_column_int64(stmt, 1);
                const path = colText(stmt, 2) orelse "";
                const title = colText(stmt, 3) orelse "";
                const is_present = c.sqlite3_column_int(stmt, 4) != 0;
                const tmdb_id: ?i64 = if (c.sqlite3_column_type(stmt, 5) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 5);
                const overview = colText(stmt, 6);
                const poster = colText(stmt, 7);
                const backdrop = colText(stmt, 8);

                const sh = schema.Show{
                    .id = id,
                    .library_id = lib_id,
                    .path = try storage.allocator.dupe(u8, path),
                    .title = try storage.allocator.dupe(u8, title),
                    .is_present = is_present,
                    .tmdb_id = tmdb_id,
                    .overview = if (overview) |o| try storage.allocator.dupe(u8, o) else null,
                    .poster_path = if (poster) |p| try storage.allocator.dupe(u8, p) else null,
                    .backdrop_path = if (backdrop) |b| try storage.allocator.dupe(u8, b) else null,
                };
                try storage.shows.put(id, sh);
                if (id >= storage.next_show_id) storage.next_show_id = id + 1;
            }
        }
    }

    // Episodes
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, show_id, file_path, season, episode, is_present, tmdb_id, title, overview, still_path, file_size FROM episodes;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const show_id = c.sqlite3_column_int64(stmt, 1);
                const file_path = colText(stmt, 2) orelse "";
                const season = c.sqlite3_column_int(stmt, 3);
                const ep_num = c.sqlite3_column_int(stmt, 4);
                const is_present = c.sqlite3_column_int(stmt, 5) != 0;
                const tmdb_id: ?i64 = if (c.sqlite3_column_type(stmt, 6) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 6);
                const title = colText(stmt, 7);
                const overview = colText(stmt, 8);
                const still = colText(stmt, 9);
                const fsize = c.sqlite3_column_int64(stmt, 10);

                const ep = schema.Episode{
                    .id = id,
                    .show_id = show_id,
                    .file_path = try storage.allocator.dupe(u8, file_path),
                    .season = season,
                    .episode = ep_num,
                    .is_present = is_present,
                    .tmdb_id = tmdb_id,
                    .title = if (title) |t| try storage.allocator.dupe(u8, t) else null,
                    .overview = if (overview) |o| try storage.allocator.dupe(u8, o) else null,
                    .still_path = if (still) |s| try storage.allocator.dupe(u8, s) else null,
                    .file_size = fsize,
                };
                try storage.episodes.put(id, ep);
                if (id >= storage.next_episode_id) storage.next_episode_id = id + 1;
            }
        }
    }
}

fn migrateLogs(allocator: std.mem.Allocator, io: std.Io, logs_storage: *logs_engine.LogsStorage, db_path: []const u8) !void {
    _ = io;
    const z_path = try allocator.dupeZ(u8, db_path);
    defer allocator.free(z_path);

    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(z_path.ptr, &db) != c.SQLITE_OK) {
        if (db) |d| _ = c.sqlite3_close(d);
        return error.SqliteOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    // Playback Progress
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT username, movie_id, position, duration, updated_at FROM playback_progress;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const uname = colText(stmt, 0) orelse continue;
                const movie_id = c.sqlite3_column_int64(stmt, 1);
                const pos = c.sqlite3_column_double(stmt, 2);
                const dur = c.sqlite3_column_double(stmt, 3);
                const upd = c.sqlite3_column_int64(stmt, 4);

                const pp = schema.PlaybackProgress{
                    .username = try logs_storage.allocator.dupe(u8, uname),
                    .movie_id = movie_id,
                    .position = pos,
                    .duration = dur,
                    .updated_at = upd,
                };
                const key = try std.fmt.allocPrint(logs_storage.allocator, "{s}:{d}", .{ pp.username, pp.movie_id });
                try logs_storage.playback_progress.put(key, pp);
            }
        }
    }

    // Episode Playback Progress
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT username, episode_id, position, duration, updated_at FROM episode_playback_progress;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const uname = colText(stmt, 0) orelse continue;
                const episode_id = c.sqlite3_column_int64(stmt, 1);
                const pos = c.sqlite3_column_double(stmt, 2);
                const dur = c.sqlite3_column_double(stmt, 3);
                const upd = c.sqlite3_column_int64(stmt, 4);

                const epp = schema.EpisodePlaybackProgress{
                    .username = try logs_storage.allocator.dupe(u8, uname),
                    .episode_id = episode_id,
                    .position = pos,
                    .duration = dur,
                    .updated_at = upd,
                };
                const key = try std.fmt.allocPrint(logs_storage.allocator, "{s}:{d}", .{ epp.username, epp.episode_id });
                try logs_storage.episode_playback_progress.put(key, epp);
            }
        }
    }

    // Playback Logs
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, username, movie_id, event_type, position, timestamp FROM playback_logs ORDER BY id ASC;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const uname = colText(stmt, 1) orelse continue;
                const movie_id = c.sqlite3_column_int64(stmt, 2);
                const ev_type = colText(stmt, 3) orelse "progress";
                const pos = c.sqlite3_column_double(stmt, 4);
                const ts = c.sqlite3_column_int64(stmt, 5);

                const pl = schema.PlaybackLog{
                    .id = id,
                    .username = try logs_storage.allocator.dupe(u8, uname),
                    .movie_id = movie_id,
                    .event_type = try logs_storage.allocator.dupe(u8, ev_type),
                    .position = pos,
                    .timestamp = ts,
                };
                try logs_storage.playback_logs.append(logs_storage.allocator, pl);
                if (id >= logs_storage.next_playback_log_id) logs_storage.next_playback_log_id = id + 1;
            }
        }
    }

    // Episode Playback Logs
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, username, episode_id, event_type, position, timestamp FROM episode_playback_logs ORDER BY id ASC;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const uname = colText(stmt, 1) orelse continue;
                const ep_id = c.sqlite3_column_int64(stmt, 2);
                const ev_type = colText(stmt, 3) orelse "progress";
                const pos = c.sqlite3_column_double(stmt, 4);
                const ts = c.sqlite3_column_int64(stmt, 5);

                const epl = schema.EpisodePlaybackLog{
                    .id = id,
                    .username = try logs_storage.allocator.dupe(u8, uname),
                    .episode_id = ep_id,
                    .event_type = try logs_storage.allocator.dupe(u8, ev_type),
                    .position = pos,
                    .timestamp = ts,
                };
                try logs_storage.episode_playback_logs.append(logs_storage.allocator, epl);
                if (id >= logs_storage.next_episode_log_id) logs_storage.next_episode_log_id = id + 1;
            }
        }
    }

    // Login Logs
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT id, username, status, ip_address, timestamp FROM login_logs ORDER BY id ASC;", -1, &stmt, null) == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(stmt);
            while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
                const id = c.sqlite3_column_int64(stmt, 0);
                const uname = colText(stmt, 1) orelse continue;
                const status = colText(stmt, 2) orelse "failed";
                const ip = colText(stmt, 3) orelse "127.0.0.1";
                const ts = c.sqlite3_column_int64(stmt, 4);

                const ll = schema.LoginLog{
                    .id = id,
                    .username = try logs_storage.allocator.dupe(u8, uname),
                    .status = try logs_storage.allocator.dupe(u8, status),
                    .ip_address = try logs_storage.allocator.dupe(u8, ip),
                    .timestamp = ts,
                };
                try logs_storage.login_logs.append(logs_storage.allocator, ll);
                if (id >= logs_storage.next_login_log_id) logs_storage.next_login_log_id = id + 1;
            }
        }
    }
}
