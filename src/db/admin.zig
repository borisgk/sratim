const std = @import("std");
const db_mod = @import("db.zig");
const users_mod = @import("users.zig");
const unmatched_mod = @import("unmatched.zig");

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

/// Queries the database for total counts and storage size of movies, shows, episodes, and other files.
pub fn getAdminStats(database: *db_mod.Database) !AdminStats {
    var stats = AdminStats{
        .total_movies = 0,
        .total_shows = 0,
        .total_episodes = 0,
        .total_other_files = 0,
        .total_storage_bytes = 0,
        .total_users = try users_mod.getUserCount(database),
        .total_unmatched = try unmatched_mod.getUnmatchedCount(database),
    };

    // Count Movies (from 'Movies' type libraries)
    {
        var stmt = try database.prepare(
            \\SELECT COUNT(*) 
            \\FROM movies 
            \\JOIN libraries ON movies.library_id = libraries.id 
            \\WHERE libraries.type = 'Movies' AND movies.is_present = 1;
        );
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            stats.total_movies = stmt.columnInt64(0);
        }
    }

    // Count Shows
    {
        var stmt = try database.prepare("SELECT COUNT(*) FROM shows WHERE is_present = 1;");
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            stats.total_shows = stmt.columnInt64(0);
        }
    }

    // Count Episodes
    {
        var stmt = try database.prepare("SELECT COUNT(*) FROM episodes WHERE is_present = 1;");
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            stats.total_episodes = stmt.columnInt64(0);
        }
    }

    // Count Other Files (from 'Other' type libraries)
    {
        var stmt = try database.prepare(
            \\SELECT COUNT(*) 
            \\FROM movies 
            \\JOIN libraries ON movies.library_id = libraries.id 
            \\WHERE libraries.type = 'Other' AND movies.is_present = 1;
        );
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            stats.total_other_files = stmt.columnInt64(0);
        }
    }

    // Movies Storage Size
    var movies_size: i64 = 0;
    {
        var stmt = try database.prepare("SELECT COALESCE(SUM(file_size), 0) FROM movies WHERE is_present = 1;");
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            movies_size = stmt.columnInt64(0);
        }
    }

    // Episodes Storage Size
    var episodes_size: i64 = 0;
    {
        var stmt = try database.prepare("SELECT COALESCE(SUM(file_size), 0) FROM episodes WHERE is_present = 1;");
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            episodes_size = stmt.columnInt64(0);
        }
    }

    const total_bytes = @as(u64, @intCast(@max(0, movies_size + episodes_size)));
    stats.total_storage_bytes = total_bytes;

    return stats;
}
