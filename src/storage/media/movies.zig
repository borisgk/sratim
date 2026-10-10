const std = @import("std");
const schema = @import("../schema.zig");
const engine = @import("../engine.zig");
const SratimStorage = engine.SratimStorage;
const sort_mod = @import("../sort.zig");

pub fn addOrUpdateMovie(self: *SratimStorage, movie: schema.Movie) !i64 {
    self.writeLock();
    defer self.writeUnlock();

    var final_id = movie.id;
    if (final_id <= 0) {
        // Find existing by library_id + file_path
        var it = self.movies.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.library_id == movie.library_id and std.mem.eql(u8, e.value_ptr.file_path, movie.file_path)) {
                final_id = e.key_ptr.*;
                break;
            }
        }
        if (final_id <= 0) {
            final_id = self.next_movie_id;
            self.next_movie_id += 1;
        }
    }

    if (self.movies.getPtr(final_id)) |existing| {
        existing.is_present = movie.is_present;
        existing.file_size = movie.file_size;
        if (!std.mem.eql(u8, existing.clean_name, movie.clean_name)) {
            self.allocator.free(existing.clean_name);
            existing.clean_name = try self.allocator.dupe(u8, movie.clean_name);
        }
        if (movie.tmdb_id) |tid| {
            existing.tmdb_id = tid;
            if (movie.title) |t| {
                if (existing.title) |old_t| self.allocator.free(old_t);
                existing.title = try self.allocator.dupe(u8, t);
            }
            if (movie.overview) |o| {
                if (existing.overview) |old_o| self.allocator.free(old_o);
                existing.overview = try self.allocator.dupe(u8, o);
            }
            if (movie.poster_path) |p| {
                if (existing.poster_path) |old_p| self.allocator.free(old_p);
                existing.poster_path = try self.allocator.dupe(u8, p);
            }
            if (movie.backdrop_path) |b| {
                if (existing.backdrop_path) |old_b| self.allocator.free(old_b);
                existing.backdrop_path = try self.allocator.dupe(u8, b);
            }
            if (movie.release_date) |r| {
                if (existing.release_date) |old_r| self.allocator.free(old_r);
                existing.release_date = try self.allocator.dupe(u8, r);
            }
        }
        return final_id;
    }

    var to_store = try movie.clone(self.allocator);
    to_store.id = final_id;
    try self.movies.put(final_id, to_store);
    return final_id;
}

pub fn getMovieById(self: *SratimStorage, allocator: std.mem.Allocator, id: i64) !?schema.Movie {
    self.readLock();
    defer self.readUnlock();

    if (self.movies.get(id)) |m| {
        return try m.clone(allocator);
    }
    return null;
}

pub fn getMoviesByLibrary(self: *SratimStorage, allocator: std.mem.Allocator, library_id: i64) ![]schema.Movie {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Movie).empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.library_id == library_id and e.value_ptr.is_present) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }

    std.sort.pdq(schema.Movie, list.items, {}, struct {
        fn lessThan(_: void, a: schema.Movie, b: schema.Movie) bool {
            const name_a = a.title orelse a.clean_name;
            const name_b = b.title orelse b.clean_name;
            return sort_mod.titleLessThan(name_a, name_b);
        }
    }.lessThan);

    return try list.toOwnedSlice(allocator);
}

pub fn getAllMovies(self: *SratimStorage, allocator: std.mem.Allocator) ![]schema.Movie {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Movie).empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn getMoviesMissingMetadata(self: *SratimStorage, allocator: std.mem.Allocator) ![]schema.Movie {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Movie).empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present and e.value_ptr.tmdb_id == null) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn getRecentMoviesByLibrary(self: *SratimStorage, allocator: std.mem.Allocator, library_id: i64, limit: usize) ![]schema.Movie {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.Movie).empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.library_id == library_id and e.value_ptr.is_present) {
            try list.append(allocator, try e.value_ptr.clone(allocator));
        }
    }

    std.sort.pdq(schema.Movie, list.items, {}, struct {
        fn lessThan(_: void, a: schema.Movie, b: schema.Movie) bool {
            return a.id > b.id;
        }
    }.lessThan);

    if (list.items.len > limit) {
        for (list.items[limit..]) |*m| m.deinit(allocator);
        list.items.len = limit;
    }

    return try list.toOwnedSlice(allocator);
}

pub fn linkMovieMetadata(
    self: *SratimStorage,
    id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    release_date: ?[]const u8,
) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.movies.getPtr(id)) |ptr| {
        const tmdb_changed = (ptr.tmdb_id == null or ptr.tmdb_id.? != tmdb_id);
        if (tmdb_changed) {
            ptr.credits_fetched = false;
            var to_remove = std.ArrayList(i64).empty;
            defer to_remove.deinit(self.allocator);
            var it = self.movie_credits.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.movie_id == id) {
                    to_remove.append(self.allocator, e.key_ptr.*) catch {};
                }
            }
            for (to_remove.items) |cid| {
                if (self.movie_credits.fetchRemove(cid)) |entry| {
                    var mut_val = entry.value;
                    mut_val.deinit(self.allocator);
                }
            }
        }
        ptr.tmdb_id = tmdb_id;
        if (ptr.title) |t| self.allocator.free(t);
        ptr.title = try self.allocator.dupe(u8, title);

        if (ptr.overview) |o| self.allocator.free(o);
        ptr.overview = if (overview) |ov| try self.allocator.dupe(u8, ov) else null;

        if (ptr.poster_path) |p| self.allocator.free(p);
        ptr.poster_path = if (poster_path) |po| try self.allocator.dupe(u8, po) else null;

        if (ptr.backdrop_path) |b| self.allocator.free(b);
        ptr.backdrop_path = if (backdrop_path) |bd| try self.allocator.dupe(u8, bd) else null;

        if (ptr.release_date) |r| self.allocator.free(r);
        ptr.release_date = if (release_date) |rd| try self.allocator.dupe(u8, rd) else null;
    } else {
        return error.MovieNotFound;
    }
}

pub fn unlinkMovieMetadata(self: *SratimStorage, id: i64) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.movies.getPtr(id)) |ptr| {
        ptr.tmdb_id = null;
        ptr.credits_fetched = false;
        var to_remove = std.ArrayList(i64).empty;
        defer to_remove.deinit(self.allocator);
        var it = self.movie_credits.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.movie_id == id) {
                to_remove.append(self.allocator, e.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |cid| {
            if (self.movie_credits.fetchRemove(cid)) |entry| {
                var mut_val = entry.value;
                mut_val.deinit(self.allocator);
            }
        }
        if (ptr.title) |t| {
            self.allocator.free(t);
            ptr.title = null;
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
        if (ptr.release_date) |r| {
            self.allocator.free(r);
            ptr.release_date = null;
        }
    }
}

pub fn countMovies(self: *SratimStorage) usize {
    self.readLock();
    defer self.readUnlock();
    var count: usize = 0;
    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present) count += 1;
    }
    return count;
}

pub fn countMoviesByLibrary(self: *SratimStorage, library_id: i64) usize {
    self.readLock();
    defer self.readUnlock();
    var count: usize = 0;
    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.library_id == library_id and e.value_ptr.is_present) count += 1;
    }
    return count;
}

pub fn countUnmatchedMovies(self: *SratimStorage) usize {
    self.readLock();
    defer self.readUnlock();
    var count: usize = 0;
    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) count += 1;
    }
    return count;
}

pub fn totalMovieStorage(self: *SratimStorage) i64 {
    self.readLock();
    defer self.readUnlock();
    var total: i64 = 0;
    var it = self.movies.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.is_present) total += e.value_ptr.file_size;
    }
    return total;
}
