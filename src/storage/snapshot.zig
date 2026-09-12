const std = @import("std");
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const SratimStorage = engine.SratimStorage;

pub const SnapshotPerson = struct {
    id: i64,
    name: []const u8,
    profile_path: ?[]const u8 = null,
    known_for_department: ?[]const u8 = null,
    details_fetched: bool = false,
    details_updated_at: i64 = 0,
    // Legacy snapshot fields for migration:
    biography: ?[]const u8 = null,
    birthday: ?[]const u8 = null,
    deathday: ?[]const u8 = null,
    place_of_birth: ?[]const u8 = null,
    imdb_id: ?[]const u8 = null,
    filmography_json: ?[]const u8 = null,
};

pub const SnapshotData = struct {
    version: u32 = 1,
    next_user_id: i64 = 1,
    next_library_id: i64 = 1,
    next_movie_id: i64 = 1,
    next_show_id: i64 = 1,
    next_episode_id: i64 = 1,
    next_credit_id: i64 = 1,
    users: []const schema.User = &.{},
    sessions: []const schema.Session = &.{},
    libraries: []const schema.Library = &.{},
    movies: []const schema.Movie = &.{},
    shows: []const schema.Show = &.{},
    episodes: []const schema.Episode = &.{},
    people: []const SnapshotPerson = &.{},
    movie_credits: []const schema.MovieCredit = &.{},
};

pub const SnapshotWriteData = struct {
    version: u32 = 1,
    next_user_id: i64 = 1,
    next_library_id: i64 = 1,
    next_movie_id: i64 = 1,
    next_show_id: i64 = 1,
    next_episode_id: i64 = 1,
    next_credit_id: i64 = 1,
    users: []const schema.User = &.{},
    sessions: []const schema.Session = &.{},
    libraries: []const schema.Library = &.{},
    movies: []const schema.Movie = &.{},
    shows: []const schema.Show = &.{},
    episodes: []const schema.Episode = &.{},
    people: []const schema.Person = &.{},
    movie_credits: []const schema.MovieCredit = &.{},
};

pub fn snapshot(self: *SratimStorage) !void {
    self.readLock();
    defer self.readUnlock();

    var user_list = std.ArrayList(schema.User).empty;
    defer user_list.deinit(self.allocator);
    var u_it = self.users.iterator();
    while (u_it.next()) |e| try user_list.append(self.allocator, e.value_ptr.*);

    var sess_list = std.ArrayList(schema.Session).empty;
    defer sess_list.deinit(self.allocator);
    var s_it = self.sessions.iterator();
    while (s_it.next()) |e| try sess_list.append(self.allocator, e.value_ptr.*);

    var lib_list = std.ArrayList(schema.Library).empty;
    defer lib_list.deinit(self.allocator);
    var l_it = self.libraries.iterator();
    while (l_it.next()) |e| try lib_list.append(self.allocator, e.value_ptr.*);

    var mov_list = std.ArrayList(schema.Movie).empty;
    defer mov_list.deinit(self.allocator);
    var m_it = self.movies.iterator();
    while (m_it.next()) |e| try mov_list.append(self.allocator, e.value_ptr.*);

    var show_list = std.ArrayList(schema.Show).empty;
    defer show_list.deinit(self.allocator);
    var sh_it = self.shows.iterator();
    while (sh_it.next()) |e| try show_list.append(self.allocator, e.value_ptr.*);

    var ep_list = std.ArrayList(schema.Episode).empty;
    defer ep_list.deinit(self.allocator);
    var ep_it = self.episodes.iterator();
    while (ep_it.next()) |e| try ep_list.append(self.allocator, e.value_ptr.*);

    var p_list = std.ArrayList(schema.Person).empty;
    defer p_list.deinit(self.allocator);
    var p_it = self.people.iterator();
    while (p_it.next()) |e| try p_list.append(self.allocator, e.value_ptr.*);

    var cr_list = std.ArrayList(schema.MovieCredit).empty;
    defer cr_list.deinit(self.allocator);
    var cr_it = self.movie_credits.iterator();
    while (cr_it.next()) |e| try cr_list.append(self.allocator, e.value_ptr.*);

    const snap = SnapshotWriteData{
        .version = 1,
        .next_user_id = self.next_user_id,
        .next_library_id = self.next_library_id,
        .next_movie_id = self.next_movie_id,
        .next_show_id = self.next_show_id,
        .next_episode_id = self.next_episode_id,
        .next_credit_id = self.next_credit_id,
        .users = user_list.items,
        .sessions = sess_list.items,
        .libraries = lib_list.items,
        .movies = mov_list.items,
        .shows = show_list.items,
        .episodes = ep_list.items,
        .people = p_list.items,
        .movie_credits = cr_list.items,
    };

    const json_str = try std.json.Stringify.valueAlloc(self.allocator, snap, .{ .whitespace = .indent_2 });
    defer self.allocator.free(json_str);

    // Write atomically to temporary file, then rename
    const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.file_path});
    defer self.allocator.free(tmp_path);

    const file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{});
    defer file.close(self.io);

    var file_buf: [65536]u8 = undefined;
    var f_writer = file.writer(self.io, &file_buf);
    try f_writer.interface.writeAll(json_str);
    try f_writer.interface.flush();

    // Atomic replace
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), self.file_path, self.io);

    // Reset WAL file since all state is snapshotted
    const wal_file = std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{}) catch return;
    wal_file.close(self.io);
}

pub fn load(self: *SratimStorage) !bool {
    self.writeLock();
    defer self.writeUnlock();

    const content = std.Io.Dir.cwd().readFileAlloc(self.io, self.file_path, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };
    defer self.allocator.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return false;

    const parsed = try std.json.parseFromSlice(SnapshotData, self.allocator, trimmed, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const val = parsed.value;
    self.next_user_id = val.next_user_id;
    self.next_library_id = val.next_library_id;
    self.next_movie_id = val.next_movie_id;
    self.next_show_id = val.next_show_id;
    self.next_episode_id = val.next_episode_id;
    self.next_credit_id = val.next_credit_id;

    for (val.users) |u| {
        const cloned = try u.clone(self.allocator);
        try self.users.put(cloned.username, cloned);
    }
    for (val.sessions) |s| {
        const cloned = try s.clone(self.allocator);
        try self.sessions.put(cloned.token, cloned);
    }
    for (val.libraries) |l| {
        const cloned = try l.clone(self.allocator);
        try self.libraries.put(cloned.id, cloned);
    }
    for (val.movies) |m| {
        const cloned = try m.clone(self.allocator);
        try self.movies.put(cloned.id, cloned);
    }
    for (val.shows) |sh| {
        const cloned = try sh.clone(self.allocator);
        try self.shows.put(cloned.id, cloned);
    }
    for (val.episodes) |ep| {
        const cloned = try ep.clone(self.allocator);
        try self.episodes.put(cloned.id, cloned);
    }
    std.Io.Dir.cwd().createDirPath(self.io, self.persons_dir) catch |err| {
        std.debug.print("Failed to ensure persons directory {s}: {}\n", .{ self.persons_dir, err });
    };

    var migrated_count: usize = 0;
    for (val.people) |p| {
        const dest_path = std.fmt.allocPrint(self.allocator, "{s}/{d}.json", .{ self.persons_dir, p.id }) catch null;
        var file_exists = false;
        if (dest_path) |dp| {
            file_exists = if (std.Io.Dir.cwd().statFile(self.io, dp, .{})) |_| true else |_| false;
        }

        const has_legacy_details = (p.biography != null or p.filmography_json != null or p.birthday != null or p.deathday != null or p.place_of_birth != null or p.imdb_id != null);

        // Automatic migration of legacy details to cold disk storage
        if ((has_legacy_details or p.details_fetched) and !file_exists) {
            if (dest_path) |dp| {
                const details = schema.PersonDetails{
                    .biography = p.biography,
                    .birthday = p.birthday,
                    .deathday = p.deathday,
                    .place_of_birth = p.place_of_birth,
                    .imdb_id = p.imdb_id,
                    .filmography_json = p.filmography_json,
                };
                if (std.json.Stringify.valueAlloc(self.allocator, details, .{})) |json_str| {
                    defer self.allocator.free(json_str);
                    if (std.Io.Dir.cwd().createFile(self.io, dp, .{})) |f| {
                        defer f.close(self.io);
                        var buf: [4096]u8 = undefined;
                        var w = f.writer(self.io, &buf);
                        w.interface.writeAll(json_str) catch {};
                        w.interface.flush() catch {};
                        migrated_count += 1;
                        file_exists = true;
                    } else |err| {
                        std.debug.print("Failed to write migrated person details for {s} ({d}): {}\n", .{ p.name, p.id, err });
                    }
                } else |_| {}
            }
        }
        if (dest_path) |dp| self.allocator.free(dp);

        const is_fetched = p.details_fetched or has_legacy_details or file_exists;
        const updated_at = if (p.details_updated_at != 0)
            p.details_updated_at
        else if (is_fetched)
            self.now()
        else
            0;

        const person_hot = schema.Person{
            .id = p.id,
            .name = try self.allocator.dupe(u8, p.name),
            .profile_path = if (p.profile_path) |pr| try self.allocator.dupe(u8, pr) else null,
            .known_for_department = if (p.known_for_department) |d| try self.allocator.dupe(u8, d) else null,
            .details_fetched = is_fetched,
            .details_updated_at = updated_at,
        };
        try self.people.put(person_hot.id, person_hot);
    }
    if (migrated_count > 0) {
        std.debug.print("Migrated {d} legacy person details to cold storage in {s}\n", .{ migrated_count, self.persons_dir });
    }
    for (val.movie_credits) |cr| {
        const cloned = try cr.clone(self.allocator);
        try self.movie_credits.put(cloned.id, cloned);
    }

    return true;
}
