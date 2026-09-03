const std = @import("std");
const db_mod = @import("db.zig");

pub const AdminStats = struct {
    total_movies: i64,
    total_shows: i64,
    total_episodes: i64,
    total_other_files: i64,
    total_storage_bytes: u64,
    total_users: i64,
    total_unmatched: i64,
};

/// Formats a byte size into a human-readable string (e.g. 14.5 GB, 1.2 TB).
pub fn formatBytes(allocator: std.mem.Allocator, bytes: u64) ![]u8 {
    const kb: f64 = 1024.0;
    const mb: f64 = kb * 1024.0;
    const gb: f64 = mb * 1024.0;
    const tb: f64 = gb * 1024.0;

    const b = @as(f64, @floatFromInt(bytes));
    if (b >= tb) {
        return try std.fmt.allocPrint(allocator, "{d:.2} TB", .{b / tb});
    } else if (b >= gb) {
        return try std.fmt.allocPrint(allocator, "{d:.2} GB", .{b / gb});
    } else if (b >= mb) {
        return try std.fmt.allocPrint(allocator, "{d:.1} MB", .{b / mb});
    } else if (b >= kb) {
        return try std.fmt.allocPrint(allocator, "{d:.1} KB", .{b / kb});
    } else {
        return try std.fmt.allocPrint(allocator, "{d} B", .{bytes});
    }
}

/// Queries the storage engine for total counts and storage size of movies, shows, episodes, and other files.
pub fn getAdminStats(database: *db_mod.Database) !AdminStats {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.rwlock.lockSharedUncancelable(cat.io);
    defer cat.rwlock.unlockShared(cat.io);

    var total_movies: i64 = 0;
    var total_other_files: i64 = 0;
    var movies_size: i64 = 0;

    var m_it = cat.movies.iterator();
    while (m_it.next()) |e| {
        if (!e.value_ptr.is_present) continue;
        movies_size += e.value_ptr.file_size;
        if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
            if (lib.lib_type == .Movies) {
                total_movies += 1;
            } else if (lib.lib_type == .Other) {
                total_other_files += 1;
            }
        }
    }

    var total_shows: i64 = 0;
    var sh_it = cat.shows.iterator();
    while (sh_it.next()) |e| {
        if (e.value_ptr.is_present) total_shows += 1;
    }

    var total_episodes: i64 = 0;
    var episodes_size: i64 = 0;
    var ep_it = cat.episodes.iterator();
    while (ep_it.next()) |e| {
        if (e.value_ptr.is_present) {
            total_episodes += 1;
            episodes_size += e.value_ptr.file_size;
        }
    }

    var unmatched_count: i64 = 0;
    var un_m = cat.movies.iterator();
    while (un_m.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
            if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
                if (lib.lib_type == .Movies) unmatched_count += 1;
            }
        }
    }
    var un_sh = cat.shows.iterator();
    while (un_sh.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
            if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
                if (lib.lib_type == .Shows) unmatched_count += 1;
            }
        }
    }

    return .{
        .total_movies = total_movies,
        .total_shows = total_shows,
        .total_episodes = total_episodes,
        .total_other_files = total_other_files,
        .total_storage_bytes = @intCast(@max(0, movies_size + episodes_size)),
        .total_users = @intCast(cat.users.count()),
        .total_unmatched = unmatched_count,
    };
}
