const std = @import("std");
const schema = @import("schema.zig");
const engine = @import("engine.zig");
const SratimStorage = engine.SratimStorage;

pub const SnapshotData = struct {
    version: u32 = 1,
    next_user_id: i64 = 1,
    next_library_id: i64 = 1,
    next_movie_id: i64 = 1,
    next_show_id: i64 = 1,
    next_episode_id: i64 = 1,
    users: []const schema.User = &.{},
    sessions: []const schema.Session = &.{},
    libraries: []const schema.Library = &.{},
    movies: []const schema.Movie = &.{},
    shows: []const schema.Show = &.{},
    episodes: []const schema.Episode = &.{},
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

    const snap = SnapshotData{
        .version = 1,
        .next_user_id = self.next_user_id,
        .next_library_id = self.next_library_id,
        .next_movie_id = self.next_movie_id,
        .next_show_id = self.next_show_id,
        .next_episode_id = self.next_episode_id,
        .users = user_list.items,
        .sessions = sess_list.items,
        .libraries = lib_list.items,
        .movies = mov_list.items,
        .shows = show_list.items,
        .episodes = ep_list.items,
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

    return true;
}
