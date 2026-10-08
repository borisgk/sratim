const std = @import("std");
const schema = @import("../schema.zig");
const engine = @import("../engine.zig");
const SratimStorage = engine.SratimStorage;

pub fn addLibrary(self: *SratimStorage, name: []const u8, path: []const u8, lib_type: schema.LibraryType) !schema.Library {
    self.writeLock();
    defer self.writeUnlock();

    const current_time = self.now();
    const id = self.next_library_id;
    self.next_library_id += 1;

    const lib = schema.Library{
        .id = id,
        .name = try self.allocator.dupe(u8, name),
        .path = try self.allocator.dupe(u8, path),
        .lib_type = lib_type,
        .is_enabled = true,
        .depth_limit = -1,
        .scan_interval = 0,
        .metadata_language = try self.allocator.dupe(u8, "en"),
        .ignore_patterns = null,
        .include_in_dashboard = true,
        .created_at = current_time,
        .updated_at = current_time,
        .last_scanned_at = null,
    };
    try self.libraries.put(id, lib);
    return lib;
}

pub fn getLibraries(self: *SratimStorage, allocator: std.mem.Allocator) ![]schema.Library {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Library).empty;
    errdefer {
        for (list.items) |*l| l.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.libraries.iterator();
    while (it.next()) |e| {
        try list.append(allocator, try e.value_ptr.clone(allocator));
    }

    // Sort by type then name
    std.sort.pdq(schema.Library, list.items, {}, struct {
        fn lessThan(_: void, a: schema.Library, b: schema.Library) bool {
            const a_order: u8 = switch (a.lib_type) {
                .Movies => 1,
                .Shows => 2,
                .Other => 3,
            };
            const b_order: u8 = switch (b.lib_type) {
                .Movies => 1,
                .Shows => 2,
                .Other => 3,
            };
            if (a_order != b_order) return a_order < b_order;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    return try list.toOwnedSlice(allocator);
}

pub fn getLibraryById(self: *SratimStorage, allocator: std.mem.Allocator, id: i64) !?schema.Library {
    self.readLock();
    defer self.readUnlock();

    if (self.libraries.get(id)) |lib| {
        return try lib.clone(allocator);
    }
    return null;
}

pub fn countLibraries(self: *SratimStorage) usize {
    self.readLock();
    defer self.readUnlock();
    return self.libraries.count();
}

pub fn updateLibraryScanTime(self: *SratimStorage, id: i64, timestamp: i64) void {
    self.writeLock();
    defer self.writeUnlock();
    if (self.libraries.getPtr(id)) |ptr| {
        ptr.last_scanned_at = timestamp;
        ptr.updated_at = timestamp;
    }
}

pub fn renameLibrary(self: *SratimStorage, id: i64, new_name: []const u8) !void {
    self.writeLock();
    defer self.writeUnlock();

    const trimmed = std.mem.trim(u8, new_name, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyLibraryName;

    if (self.libraries.getPtr(id)) |ptr| {
        const old_name = ptr.name;
        ptr.name = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(old_name);
        ptr.updated_at = self.now();
    } else {
        return error.LibraryNotFound;
    }
}

pub fn deleteLibrary(self: *SratimStorage, id: i64) void {
    self.writeLock();
    defer self.writeUnlock();
    if (self.libraries.fetchRemove(id)) |kv| {
        var val = kv.value;
        val.deinit(self.allocator);
    }
}

pub fn markAllMoviesAbsent(self: *SratimStorage, library_id: i64) void {
    self.writeLock();
    defer self.writeUnlock();
    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.library_id == library_id) {
            e.value_ptr.is_present = false;
        }
    }
}

pub fn markAllShowsAbsent(self: *SratimStorage, library_id: i64) void {
    self.writeLock();
    defer self.writeUnlock();
    var it = self.shows.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.library_id == library_id) {
            e.value_ptr.is_present = false;
            // Mark episodes absent
            var ep_it = self.episodes.iterator();
            while (ep_it.next()) |ep| {
                if (ep.value_ptr.show_id == e.key_ptr.*) {
                    ep.value_ptr.is_present = false;
                }
            }
        }
    }
}
