const std = @import("std");
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const SratimStorage = engine.SratimStorage;

/// Adds or updates a person record in storage.
pub fn addOrUpdatePerson(self: *SratimStorage, person: schema.Person) !void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.people.getPtr(person.id)) |existing| {
        self.allocator.free(existing.name);
        if (existing.profile_path) |p| self.allocator.free(p);
        if (existing.known_for_department) |d| self.allocator.free(d);

        existing.name = try self.allocator.dupe(u8, person.name);
        existing.profile_path = if (person.profile_path) |p| try self.allocator.dupe(u8, p) else null;
        existing.known_for_department = if (person.known_for_department) |d| try self.allocator.dupe(u8, d) else null;
    } else {
        const cloned = try person.clone(self.allocator);
        try self.people.put(cloned.id, cloned);
    }
}

/// Retrieves a cloned person record by TMDB Person ID.
pub fn getPersonById(self: *SratimStorage, allocator: std.mem.Allocator, person_id: i64) !?schema.Person {
    self.readLock();
    defer self.readUnlock();

    if (self.people.get(person_id)) |p| {
        return try p.clone(allocator);
    }
    return null;
}

/// Adds a single movie credit and assigns an ID if 0.
pub fn addMovieCredit(self: *SratimStorage, credit: schema.MovieCredit) !i64 {
    self.writeLock();
    defer self.writeUnlock();

    var c = credit;
    if (c.id <= 0) {
        c.id = self.next_credit_id;
        self.next_credit_id += 1;
    }

    const cloned = try c.clone(self.allocator);
    try self.movie_credits.put(cloned.id, cloned);
    return cloned.id;
}

/// Clears all credits associated with a specific movie ID.
pub fn clearMovieCredits(self: *SratimStorage, movie_id: i64) void {
    self.writeLock();
    defer self.writeUnlock();

    var to_remove = std.ArrayList(i64).empty;
    defer to_remove.deinit(self.allocator);

    var it = self.movie_credits.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.movie_id == movie_id) {
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

/// Retrieves all credits for a movie, sorted by cast order then crew.
pub fn getCreditsByMovie(self: *SratimStorage, allocator: std.mem.Allocator, movie_id: i64) ![]schema.MovieCredit {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.MovieCredit).empty;
    errdefer {
        for (list.items) |*c| c.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.movie_credits.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.movie_id == movie_id) {
            const cloned = try e.value_ptr.clone(allocator);
            try list.append(allocator, cloned);
        }
    }

    const sortFn = struct {
        fn lessThan(_: void, a: schema.MovieCredit, b: schema.MovieCredit) bool {
            if (a.is_cast != b.is_cast) {
                // Cast first, then crew
                return a.is_cast;
            }
            return a.order < b.order;
        }
    }.lessThan;

    std.mem.sort(schema.MovieCredit, list.items, {}, sortFn);
    return list.toOwnedSlice(allocator);
}

/// Retrieves all movie credits associated with a person across all movies.
pub fn getCreditsByPerson(self: *SratimStorage, allocator: std.mem.Allocator, person_id: i64) ![]schema.MovieCredit {
    self.readLock();
    defer self.readUnlock();

    var list = std.ArrayList(schema.MovieCredit).empty;
    errdefer {
        for (list.items) |*c| c.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.movie_credits.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.person_id == person_id) {
            const cloned = try e.value_ptr.clone(allocator);
            try list.append(allocator, cloned);
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Retrieves all movies from the library where this person participated (either acting or directing).
pub fn getMoviesByPerson(self: *SratimStorage, allocator: std.mem.Allocator, person_id: i64) ![]schema.Movie {
    self.readLock();
    defer self.readUnlock();

    var movie_ids = std.AutoHashMap(i64, void).init(allocator);
    defer movie_ids.deinit();

    var it = self.movie_credits.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.person_id == person_id) {
            try movie_ids.put(e.value_ptr.movie_id, {});
        }
    }

    var movies = std.ArrayList(schema.Movie).empty;
    errdefer {
        for (movies.items) |*m| m.deinit(allocator);
        movies.deinit(allocator);
    }

    var id_it = movie_ids.iterator();
    while (id_it.next()) |mid_entry| {
        if (self.movies.get(mid_entry.key_ptr.*)) |m| {
            if (m.is_present) {
                const cloned = try m.clone(allocator);
                try movies.append(allocator, cloned);
            }
        }
    }

    return movies.toOwnedSlice(allocator);
}

/// Retrieves a map from movie_id to a space-separated string of cast and crew names.
pub fn getMoviePeopleNamesMap(self: *SratimStorage, allocator: std.mem.Allocator) !std.AutoHashMap(i64, []const u8) {
    self.readLock();
    defer self.readUnlock();

    var temp_map = std.AutoHashMap(i64, std.ArrayList(u8)).init(allocator);
    defer {
        var it = temp_map.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(allocator);
        }
        temp_map.deinit();
    }

    var it = self.movie_credits.iterator();
    while (it.next()) |e| {
        const mid = e.value_ptr.movie_id;
        const res = try temp_map.getOrPut(mid);
        if (!res.found_existing) {
            res.value_ptr.* = std.ArrayList(u8).empty;
        }
        if (res.value_ptr.items.len > 0) {
            try res.value_ptr.append(allocator, ' ');
        }
        try res.value_ptr.appendSlice(allocator, e.value_ptr.name);
    }

    var result_map = std.AutoHashMap(i64, []const u8).init(allocator);
    errdefer {
        var res_it = result_map.iterator();
        while (res_it.next()) |e| {
            allocator.free(e.value_ptr.*);
        }
        result_map.deinit();
    }

    var temp_it = temp_map.iterator();
    while (temp_it.next()) |e| {
        const str = try e.value_ptr.toOwnedSlice(allocator);
        try result_map.put(e.key_ptr.*, str);
    }

    return result_map;
}

/// Checks whether any credits exist for a given movie ID.
pub fn hasMovieCredits(self: *SratimStorage, movie_id: i64) bool {
    self.readLock();
    defer self.readUnlock();

    var it = self.movie_credits.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.movie_id == movie_id) return true;
    }
    return false;
}

/// Marks a movie as having had its credits fetched (even if empty or failed).
pub fn markMovieCreditsFetched(self: *SratimStorage, movie_id: i64) void {
    self.writeLock();
    defer self.writeUnlock();

    if (self.movies.getPtr(movie_id)) |ptr| {
        ptr.credits_fetched = true;
    }
}

/// Retrieves all present movies with valid TMDB IDs that have not yet had their credits fetched or populated.
pub fn getMoviesMissingCredits(self: *SratimStorage, allocator: std.mem.Allocator) ![]schema.Movie {
    self.readLock();
    defer self.readUnlock();

    var existing_credit_movies = std.AutoHashMap(i64, void).init(allocator);
    defer existing_credit_movies.deinit();

    var it_c = self.movie_credits.iterator();
    while (it_c.next()) |e| {
        try existing_credit_movies.put(e.value_ptr.movie_id, {});
    }

    var list = std.ArrayList(schema.Movie).empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }

    var it = self.movies.iterator();
    while (it.next()) |e| {
        const m = e.value_ptr;
        if (m.is_present and m.tmdb_id != null and m.tmdb_id.? > 0) {
            if (!m.credits_fetched and !existing_credit_movies.contains(m.id)) {
                try list.append(allocator, try m.clone(allocator));
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

