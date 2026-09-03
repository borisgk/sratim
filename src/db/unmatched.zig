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

/// Retrieves all unmatched movies and shows from 'Movies' and 'Shows' type libraries.
pub fn getUnmatchedItems(database: *db_mod.Database, allocator: std.mem.Allocator) ![]UnmatchedItem {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.rwlock.lockSharedUncancelable(cat.io);
    defer cat.rwlock.unlockShared(cat.io);

    var list = std.ArrayList(UnmatchedItem).empty;
    errdefer {
        for (list.items) |item| {
            allocator.free(item.item_type);
            allocator.free(item.title);
            allocator.free(item.file_path_or_path);
            allocator.free(item.library_name);
            allocator.free(item.library_type);
        }
        list.deinit(allocator);
    }

    var m_it = cat.movies.iterator();
    while (m_it.next()) |e| {
        if (!e.value_ptr.is_present) continue;
        if (e.value_ptr.tmdb_id != null and e.value_ptr.tmdb_id.? > 0) continue;
        const lib = cat.libraries.get(e.value_ptr.library_id) orelse continue;
        if (lib.lib_type != .Movies) continue;

        try list.append(allocator, .{
            .id = e.key_ptr.*,
            .item_type = try allocator.dupe(u8, "movie"),
            .title = try allocator.dupe(u8, e.value_ptr.title orelse e.value_ptr.clean_name),
            .file_path_or_path = try allocator.dupe(u8, e.value_ptr.file_path),
            .library_name = try allocator.dupe(u8, lib.name),
            .library_type = try allocator.dupe(u8, "Movies"),
        });
    }

    var sh_it = cat.shows.iterator();
    while (sh_it.next()) |e| {
        if (!e.value_ptr.is_present) continue;
        if (e.value_ptr.tmdb_id != null and e.value_ptr.tmdb_id.? > 0) continue;
        const lib = cat.libraries.get(e.value_ptr.library_id) orelse continue;
        if (lib.lib_type != .Shows) continue;

        try list.append(allocator, .{
            .id = e.key_ptr.*,
            .item_type = try allocator.dupe(u8, "show"),
            .title = try allocator.dupe(u8, e.value_ptr.title),
            .file_path_or_path = try allocator.dupe(u8, e.value_ptr.path),
            .library_name = try allocator.dupe(u8, lib.name),
            .library_type = try allocator.dupe(u8, "Shows"),
        });
    }

    std.sort.pdq(UnmatchedItem, list.items, {}, struct {
        fn lessThan(_: void, a: UnmatchedItem, b: UnmatchedItem) bool {
            return std.mem.order(u8, a.title, b.title) == .lt;
        }
    }.lessThan);

    return try list.toOwnedSlice(allocator);
}

/// Returns count of all unmatched movies and shows in 'Movies' and 'Shows' libraries.
pub fn getUnmatchedCount(database: *db_mod.Database) !i64 {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.rwlock.lockSharedUncancelable(cat.io);
    defer cat.rwlock.unlockShared(cat.io);

    var count: i64 = 0;
    var m_it = cat.movies.iterator();
    while (m_it.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
            if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
                if (lib.lib_type == .Movies) count += 1;
            }
        }
    }
    var sh_it = cat.shows.iterator();
    while (sh_it.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
            if (cat.libraries.get(e.value_ptr.library_id)) |lib| {
                if (lib.lib_type == .Shows) count += 1;
            }
        }
    }
    return count;
}
