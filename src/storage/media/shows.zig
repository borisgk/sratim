const std = @import("std");
const schema = @import("../schema.zig");
const engine = @import("../engine.zig");
const SratimStorage = engine.SratimStorage;
const sort_mod = @import("../sort.zig");

pub fn addOrUpdateShow(self: *SratimStorage, show: schema.Show) !i64 {
    self.writeLock();
    defer self.writeUnlock();

    var final_id = show.id;
    if (final_id <= 0) {
        var it = self.shows.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.library_id == show.library_id and std.mem.eql(u8, e.value_ptr.path, show.path)) {
                final_id = e.key_ptr.*;
                break;
            }
        }
        if (final_id <= 0) {
            final_id = self.next_show_id;
            self.next_show_id += 1;
        }
    }

    if (self.shows.getPtr(final_id)) |existing| {
        existing.is_present = show.is_present;
        if (show.tmdb_id) |tid| {
            existing.tmdb_id = tid;
            if (existing.title.len == 0 or !std.mem.eql(u8, existing.title, show.title)) {
                self.allocator.free(existing.title);
                existing.title = try self.allocator.dupe(u8, show.title);
            }
            if (show.overview) |o| {
                if (existing.overview) |old_o| self.allocator.free(old_o);
                existing.overview = try self.allocator.dupe(u8, o);
            }
            if (show.poster_path) |p| {
                if (existing.poster_path) |old_p| self.allocator.free(old_p);
                existing.poster_path = try self.allocator.dupe(u8, p);
            }
            if (show.backdrop_path) |b| {
                if (existing.backdrop_path) |old_b| self.allocator.free(old_b);
                existing.backdrop_path = try self.allocator.dupe(u8, b);
            }
        }
        return final_id;
    }

    var to_store = try show.clone(self.allocator);
    to_store.id = final_id;
    try self.shows.put(final_id, to_store);
    return final_id;
}

pub fn getShowById(self: *SratimStorage, allocator: std.mem.Allocator, id: i64) !?schema.Show {
    self.readLock();
    defer self.readUnlock();

    if (self.shows.get(id)) |sh| {
        return try sh.clone(allocator);
    }
    return null;
}

pub fn getShowsByLibrary(self: *SratimStorage, allocator: std.mem.Allocator, library_id: i64) ![]schema.Show {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Show).empty;
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.shows.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.library_id == library_id and e.value_ptr.is_present) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }

    std.sort.pdq(schema.Show, list.items, {}, struct {
        fn lessThan(_: void, a: schema.Show, b: schema.Show) bool {
            return sort_mod.titleLessThan(a.title, b.title);
        }
    }.lessThan);

    return try list.toOwnedSlice(allocator);
}

pub fn getAllShows(self: *SratimStorage, allocator: std.mem.Allocator) ![]schema.Show {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Show).empty;
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.shows.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn getShowsMissingMetadata(self: *SratimStorage, allocator: std.mem.Allocator) ![]schema.Show {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Show).empty;
    errdefer {
        for (list.items) |*s| s.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.shows.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present and e.value_ptr.tmdb_id == null) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn linkShowMetadata(
    self: *SratimStorage,
    id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.shows.getPtr(id)) |ptr| {
        const tmdb_changed = (ptr.tmdb_id == null or ptr.tmdb_id.? != tmdb_id);
        if (tmdb_changed) {
            ptr.credits_fetched = false;
            var to_remove = std.ArrayList(i64).empty;
            defer to_remove.deinit(self.allocator);
            var it = self.show_credits.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.show_id == id) {
                    to_remove.append(self.allocator, e.key_ptr.*) catch {};
                }
            }
            for (to_remove.items) |cid| {
                if (self.show_credits.fetchRemove(cid)) |entry| {
                    var mut_val = entry.value;
                    mut_val.deinit(self.allocator);
                }
            }
        }
        ptr.tmdb_id = tmdb_id;
        self.allocator.free(ptr.title);
        ptr.title = try self.allocator.dupe(u8, title);

        if (ptr.overview) |o| self.allocator.free(o);
        ptr.overview = if (overview) |ov| try self.allocator.dupe(u8, ov) else null;

        if (ptr.poster_path) |p| self.allocator.free(p);
        ptr.poster_path = if (poster_path) |po| try self.allocator.dupe(u8, po) else null;

        if (ptr.backdrop_path) |b| self.allocator.free(b);
        ptr.backdrop_path = if (backdrop_path) |bd| try self.allocator.dupe(u8, bd) else null;
    } else {
        return error.ShowNotFound;
    }
}

pub fn unlinkShowMetadata(self: *SratimStorage, id: i64) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.shows.getPtr(id)) |ptr| {
        ptr.tmdb_id = null;
        ptr.credits_fetched = false;
        var to_remove = std.ArrayList(i64).empty;
        defer to_remove.deinit(self.allocator);
        var it = self.show_credits.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.show_id == id) {
                to_remove.append(self.allocator, e.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |cid| {
            if (self.show_credits.fetchRemove(cid)) |entry| {
                var mut_val = entry.value;
                mut_val.deinit(self.allocator);
            }
        }
        if (ptr.overview) |o| {
            self.allocator.free(o);
            ptr.overview = null;
        }
        if (ptr.poster_path) |p| {
            self.allocator.free(p);
            ptr.poster_path = null;
        }
        if (ptr.backdrop_path) |b| {
            self.allocator.free(b);
            ptr.backdrop_path = null;
        }
    }
}

pub fn countShows(self: *SratimStorage) usize {
    self.readLock();
    defer self.readUnlock();
    var count: usize = 0;
    var it = self.shows.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present) count += 1;
    }
    return count;
}

pub fn countUnmatchedShows(self: *SratimStorage) usize {
    self.readLock();
    defer self.readUnlock();
    var count: usize = 0;
    var it = self.shows.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) count += 1;
    }
    return count;
}

pub fn addOrUpdateEpisode(self: *SratimStorage, episode: schema.Episode) !i64 {
    self.writeLock();
    defer self.writeUnlock();

    var final_id = episode.id;
    if (final_id <= 0) {
        var it = self.episodes.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.show_id == episode.show_id and std.mem.eql(u8, e.value_ptr.file_path, episode.file_path)) {
                final_id = e.key_ptr.*;
                break;
            }
        }
        if (final_id <= 0) {
            final_id = self.next_episode_id;
            self.next_episode_id += 1;
        }
    }

    if (self.episodes.getPtr(final_id)) |existing| {
        existing.is_present = episode.is_present;
        existing.file_size = episode.file_size;
        existing.season = episode.season;
        existing.episode = episode.episode;
        if (episode.tmdb_id) |tid| {
            existing.tmdb_id = tid;
            if (episode.title) |t| {
                if (existing.title) |old_t| self.allocator.free(old_t);
                existing.title = try self.allocator.dupe(u8, t);
            }
            if (episode.overview) |o| {
                if (existing.overview) |old_o| self.allocator.free(old_o);
                existing.overview = try self.allocator.dupe(u8, o);
            }
            if (episode.still_path) |s| {
                if (existing.still_path) |old_s| self.allocator.free(old_s);
                existing.still_path = try self.allocator.dupe(u8, s);
            }
        }
        return final_id;
    }

    var to_store = try episode.clone(self.allocator);
    to_store.id = final_id;
    try self.episodes.put(final_id, to_store);
    return final_id;
}

pub fn getEpisodeById(self: *SratimStorage, allocator: std.mem.Allocator, id: i64) !?schema.Episode {
    self.readLock();
    defer self.readUnlock();

    if (self.episodes.get(id)) |ep| {
        return try ep.clone(allocator);
    }
    return null;
}

pub fn getEpisodesByShow(self: *SratimStorage, allocator: std.mem.Allocator, show_id: i64) ![]schema.Episode {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Episode).empty;
    errdefer {
        for (list.items) |*ep| ep.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.episodes.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.show_id == show_id and e.value_ptr.is_present) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }

    std.sort.pdq(schema.Episode, list.items, {}, struct {
        fn lessThan(_: void, a: schema.Episode, b: schema.Episode) bool {
            if (a.season != b.season) return a.season < b.season;
            return a.episode < b.episode;
        }
    }.lessThan);

    return try list.toOwnedSlice(allocator);
}

pub fn linkEpisodeMetadata(
    self: *SratimStorage,
    id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    still_path: ?[]const u8,
) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.episodes.getPtr(id)) |ptr| {
        ptr.tmdb_id = tmdb_id;
        if (ptr.title) |t| self.allocator.free(t);
        ptr.title = try self.allocator.dupe(u8, title);

        if (ptr.overview) |o| self.allocator.free(o);
        ptr.overview = if (overview) |ov| try self.allocator.dupe(u8, ov) else null;

        if (ptr.still_path) |s| self.allocator.free(s);
        ptr.still_path = if (still_path) |sp| try self.allocator.dupe(u8, sp) else null;
    } else {
        return error.EpisodeNotFound;
    }
}

pub fn countEpisodes(self: *SratimStorage) usize {
    self.readLock();
    defer self.readUnlock();
    var count: usize = 0;
    var it = self.episodes.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present) count += 1;
    }
    return count;
}

pub fn totalEpisodeStorage(self: *SratimStorage) i64 {
    self.readLock();
    defer self.readUnlock();
    var total: i64 = 0;
    var it = self.episodes.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present) total += e.value_ptr.file_size;
    }
    return total;
}
