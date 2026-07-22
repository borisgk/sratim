const std = @import("std");
const db_mod = @import("db.zig");

pub const UnmatchedItem = struct {
    id: i64,
    item_type: []const u8, // "movie" or "show"
    title: []const u8,
    file_path_or_path: []const u8,
    library_name: []const u8,
    library_type: []const u8,
};

/// Retrieves all unmatched movies and shows from 'Movies' and 'Shows' type libraries (where tmdb_id IS NULL OR tmdb_id = 0).
/// Excludes 'Other' type libraries.
pub fn getUnmatchedItems(database: *db_mod.Database, allocator: std.mem.Allocator) ![]UnmatchedItem {
    var list = std.ArrayList(UnmatchedItem).empty;
    defer list.deinit(allocator);

    // Unmatched Movies (Only from 'Movies' type libraries)
    {
        var stmt = try database.prepare(
            \\SELECT m.id, COALESCE(m.title, m.clean_name), m.file_path, l.name, l.type
            \\FROM movies m
            \\JOIN libraries l ON m.library_id = l.id
            \\WHERE m.is_present = 1 
            \\  AND l.type = 'Movies' 
            \\  AND (m.tmdb_id IS NULL OR m.tmdb_id = 0)
            \\ORDER BY m.clean_name ASC;
        );
        defer stmt.finalize();

        while ((try stmt.step()) == .row) {
            const id = stmt.columnInt64(0);
            const title_raw = stmt.columnText(1) orelse "Unknown";
            const path_raw = stmt.columnText(2) orelse "";
            const lib_name_raw = stmt.columnText(3) orelse "Library";
            const lib_type_raw = stmt.columnText(4) orelse "Movies";

            try list.append(allocator, .{
                .id = id,
                .item_type = try allocator.dupe(u8, "movie"),
                .title = try allocator.dupe(u8, title_raw),
                .file_path_or_path = try allocator.dupe(u8, path_raw),
                .library_name = try allocator.dupe(u8, lib_name_raw),
                .library_type = try allocator.dupe(u8, lib_type_raw),
            });
        }
    }

    // Unmatched TV Shows (Only from 'Shows' type libraries)
    {
        var stmt = try database.prepare(
            \\SELECT s.id, s.title, s.path, l.name, l.type
            \\FROM shows s
            \\JOIN libraries l ON s.library_id = l.id
            \\WHERE s.is_present = 1 
            \\  AND l.type = 'Shows' 
            \\  AND (s.tmdb_id IS NULL OR s.tmdb_id = 0)
            \\ORDER BY s.title ASC;
        );
        defer stmt.finalize();

        while ((try stmt.step()) == .row) {
            const id = stmt.columnInt64(0);
            const title_raw = stmt.columnText(1) orelse "Unknown";
            const path_raw = stmt.columnText(2) orelse "";
            const lib_name_raw = stmt.columnText(3) orelse "Library";
            const lib_type_raw = stmt.columnText(4) orelse "Shows";

            try list.append(allocator, .{
                .id = id,
                .item_type = try allocator.dupe(u8, "show"),
                .title = try allocator.dupe(u8, title_raw),
                .file_path_or_path = try allocator.dupe(u8, path_raw),
                .library_name = try allocator.dupe(u8, lib_name_raw),
                .library_type = try allocator.dupe(u8, lib_type_raw),
            });
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Returns count of all unmatched movies and shows in 'Movies' and 'Shows' libraries.
pub fn getUnmatchedCount(database: *db_mod.Database) !i64 {
    var count: i64 = 0;

    {
        var stmt = try database.prepare(
            \\SELECT COUNT(*) 
            \\FROM movies m 
            \\JOIN libraries l ON m.library_id = l.id 
            \\WHERE m.is_present = 1 AND l.type = 'Movies' AND (m.tmdb_id IS NULL OR m.tmdb_id = 0);
        );
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            count += stmt.columnInt64(0);
        }
    }

    {
        var stmt = try database.prepare(
            \\SELECT COUNT(*) 
            \\FROM shows s 
            \\JOIN libraries l ON s.library_id = l.id 
            \\WHERE s.is_present = 1 AND l.type = 'Shows' AND (s.tmdb_id IS NULL OR s.tmdb_id = 0);
        );
        defer stmt.finalize();
        if ((try stmt.step()) == .row) {
            count += stmt.columnInt64(0);
        }
    }

    return count;
}
