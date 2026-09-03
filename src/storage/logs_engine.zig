const std = @import("std");
const schema = @import("schema.zig");

pub const LogsStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    wal_path: []const u8,
    rwlock: std.Io.RwLock = .init,

    playback_progress: std.StringHashMap(schema.PlaybackProgress),
    episode_playback_progress: std.StringHashMap(schema.EpisodePlaybackProgress),
    playback_logs: std.ArrayList(schema.PlaybackLog),
    episode_playback_logs: std.ArrayList(schema.EpisodePlaybackLog),
    login_logs: std.ArrayList(schema.LoginLog),

    next_playback_log_id: i64 = 1,
    next_episode_log_id: i64 = 1,
    next_login_log_id: i64 = 1,

    fn writeLock(self: *LogsStorage) void {
        self.rwlock.lockUncancelable(self.io);
    }
    fn writeUnlock(self: *LogsStorage) void {
        self.rwlock.unlock(self.io);
    }
    fn readLock(self: *LogsStorage) void {
        self.rwlock.lockSharedUncancelable(self.io);
    }
    fn readUnlock(self: *LogsStorage) void {
        self.rwlock.unlockShared(self.io);
    }

    fn now(self: *const LogsStorage) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, wal_path: []const u8) LogsStorage {
        return .{
            .allocator = allocator,
            .io = io,
            .file_path = file_path,
            .wal_path = wal_path,
            .playback_progress = std.StringHashMap(schema.PlaybackProgress).init(allocator),
            .episode_playback_progress = std.StringHashMap(schema.EpisodePlaybackProgress).init(allocator),
            .playback_logs = std.ArrayList(schema.PlaybackLog).empty,
            .episode_playback_logs = std.ArrayList(schema.EpisodePlaybackLog).empty,
            .login_logs = std.ArrayList(schema.LoginLog).empty,
        };
    }

    pub fn deinit(self: *LogsStorage) void {
        self.writeLock();
        defer self.writeUnlock();

        var pp_iter = self.playback_progress.iterator();
        while (pp_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.playback_progress.deinit();

        var epp_iter = self.episode_playback_progress.iterator();
        while (epp_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.episode_playback_progress.deinit();

        for (self.playback_logs.items) |*pl| pl.deinit(self.allocator);
        self.playback_logs.deinit(self.allocator);

        for (self.episode_playback_logs.items) |*epl| epl.deinit(self.allocator);
        self.episode_playback_logs.deinit(self.allocator);

        for (self.login_logs.items) |*ll| ll.deinit(self.allocator);
        self.login_logs.deinit(self.allocator);
    }

    const SnapshotData = struct {
        version: u32 = 1,
        next_playback_log_id: i64 = 1,
        next_episode_log_id: i64 = 1,
        next_login_log_id: i64 = 1,
        playback_progress: []const schema.PlaybackProgress,
        episode_playback_progress: []const schema.EpisodePlaybackProgress,
        playback_logs: []const schema.PlaybackLog,
        episode_playback_logs: []const schema.EpisodePlaybackLog,
        login_logs: []const schema.LoginLog,
    };

    pub fn snapshot(self: *LogsStorage) !void {
        self.readLock();
        defer self.readUnlock();

        var pp_list = std.ArrayList(schema.PlaybackProgress).empty;
        defer pp_list.deinit(self.allocator);
        var pp_it = self.playback_progress.iterator();
        while (pp_it.next()) |e| try pp_list.append(self.allocator, e.value_ptr.*);

        var epp_list = std.ArrayList(schema.EpisodePlaybackProgress).empty;
        defer epp_list.deinit(self.allocator);
        var epp_it = self.episode_playback_progress.iterator();
        while (epp_it.next()) |e| try epp_list.append(self.allocator, e.value_ptr.*);

        const snap = SnapshotData{
            .version = 1,
            .next_playback_log_id = self.next_playback_log_id,
            .next_episode_log_id = self.next_episode_log_id,
            .next_login_log_id = self.next_login_log_id,
            .playback_progress = pp_list.items,
            .episode_playback_progress = epp_list.items,
            .playback_logs = self.playback_logs.items,
            .episode_playback_logs = self.episode_playback_logs.items,
            .login_logs = self.login_logs.items,
        };

        const json_str = try std.json.Stringify.valueAlloc(self.allocator, snap, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_str);

        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{self.file_path});
        defer self.allocator.free(tmp_path);

        const file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{});
        defer file.close(self.io);

        var file_buf: [65536]u8 = undefined;
        var f_writer = file.writer(self.io, &file_buf);
        try f_writer.interface.writeAll(json_str);
        try f_writer.interface.flush();

        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), self.file_path, self.io);

        const wal_file = std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{}) catch return;
        wal_file.close(self.io);
    }

    pub fn load(self: *LogsStorage) !bool {
        self.writeLock();
        defer self.writeUnlock();

        const content = std.Io.Dir.cwd().readFileAlloc(self.io, self.file_path, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return false;
            return err;
        };
        defer self.allocator.free(content);

        const parsed = try std.json.parseFromSlice(SnapshotData, self.allocator, content, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const val = parsed.value;
        self.next_playback_log_id = val.next_playback_log_id;
        self.next_episode_log_id = val.next_episode_log_id;
        self.next_login_log_id = val.next_login_log_id;

        for (val.playback_progress) |pp| {
            const cloned = try pp.clone(self.allocator);
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ cloned.username, cloned.movie_id });
            try self.playback_progress.put(key, cloned);
        }

        for (val.episode_playback_progress) |epp| {
            const cloned = try epp.clone(self.allocator);
            const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ cloned.username, cloned.episode_id });
            try self.episode_playback_progress.put(key, cloned);
        }

        for (val.playback_logs) |pl| {
            try self.playback_logs.append(self.allocator, try pl.clone(self.allocator));
        }

        for (val.episode_playback_logs) |epl| {
            try self.episode_playback_logs.append(self.allocator, try epl.clone(self.allocator));
        }

        for (val.login_logs) |ll| {
            try self.login_logs.append(self.allocator, try ll.clone(self.allocator));
        }

        return true;
    }

    // =========================================================================
    // Login Logs Operations
    // =========================================================================

    pub fn logLoginAttempt(self: *LogsStorage, username: []const u8, status: []const u8, ip_address: []const u8) !void {
        self.writeLock();
        defer self.writeUnlock();

        const id = self.next_login_log_id;
        self.next_login_log_id += 1;

        const log = schema.LoginLog{
            .id = id,
            .username = try self.allocator.dupe(u8, username),
            .status = try self.allocator.dupe(u8, status),
            .ip_address = try self.allocator.dupe(u8, ip_address),
            .timestamp = self.now(),
        };
        try self.login_logs.append(self.allocator, log);
    }

    pub fn getFailedLoginAttempts(self: *LogsStorage, username: []const u8, window_seconds: i64) usize {
        self.readLock();
        defer self.readUnlock();

        const threshold = self.now() - window_seconds;
        var count: usize = 0;
        for (self.login_logs.items) |ll| {
            if (ll.timestamp >= threshold and std.mem.eql(u8, ll.username, username) and std.mem.eql(u8, ll.status, "failed")) {
                count += 1;
            }
        }
        return count;
    }

    pub fn clearFailedLogins(self: *LogsStorage, username: []const u8) void {
        self.writeLock();
        defer self.writeUnlock();

        var i: usize = 0;
        while (i < self.login_logs.items.len) {
            const ll = &self.login_logs.items[i];
            if (std.mem.eql(u8, ll.username, username) and std.mem.eql(u8, ll.status, "failed")) {
                ll.deinit(self.allocator);
                _ = self.login_logs.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // =========================================================================
    // Movie Playback Progress & Logs
    // =========================================================================

    pub fn logPlaybackEvent(self: *LogsStorage, username: []const u8, movie_id: i64, event_type: []const u8, position: f64) !void {
        self.writeLock();
        defer self.writeUnlock();

        const id = self.next_playback_log_id;
        self.next_playback_log_id += 1;

        const log = schema.PlaybackLog{
            .id = id,
            .username = try self.allocator.dupe(u8, username),
            .movie_id = movie_id,
            .event_type = try self.allocator.dupe(u8, event_type),
            .position = position,
            .timestamp = self.now(),
        };
        try self.playback_logs.append(self.allocator, log);
    }

    pub fn savePlaybackProgress(self: *LogsStorage, username: []const u8, movie_id: i64, position: f64, duration: f64) !void {
        self.writeLock();
        defer self.writeUnlock();

        const current_time = self.now();
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ username, movie_id });

        if (self.playback_progress.getPtr(key)) |ptr| {
            ptr.position = position;
            ptr.duration = duration;
            ptr.updated_at = current_time;
            self.allocator.free(key);
        } else {
            const pp = schema.PlaybackProgress{
                .username = try self.allocator.dupe(u8, username),
                .movie_id = movie_id,
                .position = position,
                .duration = duration,
                .updated_at = current_time,
            };
            try self.playback_progress.put(key, pp);
        }
    }

    pub fn getPlaybackProgress(self: *LogsStorage, username: []const u8, movie_id: i64) f64 {
        self.readLock();
        defer self.readUnlock();

        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ username, movie_id }) catch return 0.0;
        if (self.playback_progress.get(key)) |pp| {
            return pp.position;
        }
        return 0.0;
    }

    pub fn getProgressForUser(self: *LogsStorage, allocator: std.mem.Allocator, username: []const u8) ![]schema.PlaybackProgress {
        self.readLock();
        defer self.readUnlock();

        var list = std.ArrayList(schema.PlaybackProgress).empty;
        errdefer {
            for (list.items) |*p| p.deinit(allocator);
            list.deinit(allocator);
        }

        var it = self.playback_progress.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.username, username)) {
                try list.append(allocator, try e.value_ptr.clone(allocator));
            }
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn deletePlaybackProgress(self: *LogsStorage, username: []const u8, movie_id: i64) void {
        self.writeLock();
        defer self.writeUnlock();

        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ username, movie_id }) catch return;
        if (self.playback_progress.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit(self.allocator);
        }
    }

    // =========================================================================
    // Episode Playback Progress & Logs
    // =========================================================================

    pub fn logEpisodePlaybackEvent(self: *LogsStorage, username: []const u8, episode_id: i64, event_type: []const u8, position: f64) !void {
        self.writeLock();
        defer self.writeUnlock();

        const id = self.next_episode_log_id;
        self.next_episode_log_id += 1;

        const log = schema.EpisodePlaybackLog{
            .id = id,
            .username = try self.allocator.dupe(u8, username),
            .episode_id = episode_id,
            .event_type = try self.allocator.dupe(u8, event_type),
            .position = position,
            .timestamp = self.now(),
        };
        try self.episode_playback_logs.append(self.allocator, log);
    }

    pub fn saveEpisodePlaybackProgress(self: *LogsStorage, username: []const u8, episode_id: i64, position: f64, duration: f64) !void {
        self.writeLock();
        defer self.writeUnlock();

        const current_time = self.now();
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ username, episode_id });

        if (self.episode_playback_progress.getPtr(key)) |ptr| {
            ptr.position = position;
            ptr.duration = duration;
            ptr.updated_at = current_time;
            self.allocator.free(key);
        } else {
            const epp = schema.EpisodePlaybackProgress{
                .username = try self.allocator.dupe(u8, username),
                .episode_id = episode_id,
                .position = position,
                .duration = duration,
                .updated_at = current_time,
            };
            try self.episode_playback_progress.put(key, epp);
        }
    }

    pub fn getEpisodePlaybackProgress(self: *LogsStorage, username: []const u8, episode_id: i64) f64 {
        self.readLock();
        defer self.readUnlock();

        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ username, episode_id }) catch return 0.0;
        if (self.episode_playback_progress.get(key)) |epp| {
            return epp.position;
        }
        return 0.0;
    }

    pub fn getEpisodeProgressForUser(self: *LogsStorage, allocator: std.mem.Allocator, username: []const u8) ![]schema.EpisodePlaybackProgress {
        self.readLock();
        defer self.readUnlock();

        var list = std.ArrayList(schema.EpisodePlaybackProgress).empty;
        errdefer {
            for (list.items) |*p| p.deinit(allocator);
            list.deinit(allocator);
        }

        var it = self.episode_playback_progress.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.username, username)) {
                try list.append(allocator, try e.value_ptr.clone(allocator));
            }
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn deleteEpisodePlaybackProgress(self: *LogsStorage, username: []const u8, episode_id: i64) void {
        self.writeLock();
        defer self.writeUnlock();

        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ username, episode_id }) catch return;
        if (self.episode_playback_progress.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit(self.allocator);
        }
    }

    // =========================================================================
    // Recently Watched
    // =========================================================================

    pub const RecentlyWatchedItem = struct {
        media_type: enum { movie, episode },
        item_id: i64,
        position: f64,
        duration: f64,
        updated_at: i64,
    };

    pub fn getRecentlyWatched(self: *LogsStorage, allocator: std.mem.Allocator, username: []const u8, limit: usize) ![]RecentlyWatchedItem {
        self.readLock();
        defer self.readUnlock();

        var list = std.ArrayList(RecentlyWatchedItem).empty;
        errdefer list.deinit(allocator);

        var m_it = self.playback_progress.iterator();
        while (m_it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.username, username)) {
                // Must be in-progress (e.g. > 10s and not completed)
                if (e.value_ptr.position > 10.0 and (e.value_ptr.duration <= 0 or e.value_ptr.position < e.value_ptr.duration * 0.95)) {
                    try list.append(allocator, .{
                        .media_type = .movie,
                        .item_id = e.value_ptr.movie_id,
                        .position = e.value_ptr.position,
                        .duration = e.value_ptr.duration,
                        .updated_at = e.value_ptr.updated_at,
                    });
                }
            }
        }

        var ep_it = self.episode_playback_progress.iterator();
        while (ep_it.next()) |e| {
            if (std.mem.eql(u8, e.value_ptr.username, username)) {
                if (e.value_ptr.position > 10.0 and (e.value_ptr.duration <= 0 or e.value_ptr.position < e.value_ptr.duration * 0.95)) {
                    try list.append(allocator, .{
                        .media_type = .episode,
                        .item_id = e.value_ptr.episode_id,
                        .position = e.value_ptr.position,
                        .duration = e.value_ptr.duration,
                        .updated_at = e.value_ptr.updated_at,
                    });
                }
            }
        }

        std.sort.pdq(RecentlyWatchedItem, list.items, {}, struct {
            fn lessThan(_: void, a: RecentlyWatchedItem, b: RecentlyWatchedItem) bool {
                return a.updated_at > b.updated_at; // Newest first
            }
        }.lessThan);

        if (list.items.len > limit) {
            list.items.len = limit;
        }

        return try list.toOwnedSlice(allocator);
    }
};
