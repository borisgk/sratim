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

    uncompacted_wal_records: usize = 0,

    const WalOpcode = enum(u8) {
        save_playback_progress = 1,
        save_episode_playback_progress = 2,
        delete_playback_progress = 3,
        delete_episode_playback_progress = 4,
        log_playback_event = 5,
        log_episode_playback_event = 6,
        log_login_attempt = 7,
        clear_failed_logins = 8,
        _,
    };

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
            .uncompacted_wal_records = 0,
            .playback_progress = std.StringHashMap(schema.PlaybackProgress).init(allocator),
            .episode_playback_progress = std.StringHashMap(schema.EpisodePlaybackProgress).init(allocator),
            .playback_logs = std.ArrayList(schema.PlaybackLog).empty,
            .episode_playback_logs = std.ArrayList(schema.EpisodePlaybackLog).empty,
            .login_logs = std.ArrayList(schema.LoginLog).empty,
        };
    }

    fn freeMemory(self: *LogsStorage) void {
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

    pub fn deinit(self: *LogsStorage) void {
        self.writeLock();
        defer self.writeUnlock();

        if (self.uncompacted_wal_records > 0) {
            self.snapshotLocked() catch {};
        }
        self.freeMemory();
    }

    pub fn deinitWithoutSnapshot(self: *LogsStorage) void {
        self.writeLock();
        defer self.writeUnlock();
        self.freeMemory();
    }

    const SnapshotData = struct {
        version: u32 = 1,
        next_playback_log_id: i64 = 1,
        next_episode_log_id: i64 = 1,
        next_login_log_id: i64 = 1,
        playback_progress: []const schema.PlaybackProgress = &.{},
        episode_playback_progress: []const schema.EpisodePlaybackProgress = &.{},
        playback_logs: []const schema.PlaybackLog = &.{},
        episode_playback_logs: []const schema.EpisodePlaybackLog = &.{},
        login_logs: []const schema.LoginLog = &.{},
    };

    fn snapshotLocked(self: *LogsStorage) !void {
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

        // Reset WAL file since all state is snapshotted
        const wal_file = std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{}) catch return;
        wal_file.close(self.io);
        self.uncompacted_wal_records = 0;
    }

    pub fn snapshot(self: *LogsStorage) !void {
        self.readLock();
        defer self.readUnlock();
        try self.snapshotLocked();
    }

    fn writeWalRecord(self: *LogsStorage, payload: []const u8) void {
        const magic = "WAL1";
        const payload_len: u32 = @intCast(payload.len);
        const crc = std.hash.Crc32.hash(payload);

        var header: [12]u8 = undefined;
        @memcpy(header[0..4], magic);
        std.mem.writeInt(u32, header[4..8], payload_len, .little);
        std.mem.writeInt(u32, header[8..12], crc, .little);

        const file = std.Io.Dir.cwd().createFile(self.io, self.wal_path, .{
            .truncate = false,
        }) catch |err| {
            std.debug.print("LogsStorage: failed to open WAL file {s}: {}\n", .{ self.wal_path, err });
            return;
        };
        defer file.close(self.io);

        const offset = file.length(self.io) catch 0;
        var frame_buf: [512]u8 = undefined;
        const total_len = 12 + payload.len;
        if (total_len <= frame_buf.len) {
            @memcpy(frame_buf[0..12], &header);
            @memcpy(frame_buf[12..total_len], payload);
            file.writePositionalAll(self.io, frame_buf[0..total_len], offset) catch return;
        } else {
            file.writePositionalAll(self.io, &header, offset) catch return;
            file.writePositionalAll(self.io, payload, offset + 12) catch return;
        }
        file.sync(self.io) catch {};

        self.uncompacted_wal_records += 1;
        if (self.uncompacted_wal_records >= 200 or offset + total_len >= 512 * 1024) {
            self.snapshotLocked() catch {};
        }
    }

    fn writeWalSavePlaybackProgress(self: *LogsStorage, username: []const u8, movie_id: i64, position: f64, duration: f64, updated_at: i64) void {
        var buf: [256]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.save_playback_progress);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        std.mem.writeInt(i64, buf[pos..][0..8], movie_id, .little);
        pos += 8;
        std.mem.writeInt(u64, buf[pos..][0..8], @as(u64, @bitCast(position)), .little);
        pos += 8;
        std.mem.writeInt(u64, buf[pos..][0..8], @as(u64, @bitCast(duration)), .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], updated_at, .little);
        pos += 8;
        self.writeWalRecord(buf[0..pos]);
    }

    fn writeWalSaveEpisodePlaybackProgress(self: *LogsStorage, username: []const u8, episode_id: i64, position: f64, duration: f64, updated_at: i64) void {
        var buf: [256]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.save_episode_playback_progress);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        std.mem.writeInt(i64, buf[pos..][0..8], episode_id, .little);
        pos += 8;
        std.mem.writeInt(u64, buf[pos..][0..8], @as(u64, @bitCast(position)), .little);
        pos += 8;
        std.mem.writeInt(u64, buf[pos..][0..8], @as(u64, @bitCast(duration)), .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], updated_at, .little);
        pos += 8;
        self.writeWalRecord(buf[0..pos]);
    }

    fn writeWalDeletePlaybackProgress(self: *LogsStorage, username: []const u8, movie_id: i64) void {
        var buf: [256]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.delete_playback_progress);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        std.mem.writeInt(i64, buf[pos..][0..8], movie_id, .little);
        pos += 8;
        self.writeWalRecord(buf[0..pos]);
    }

    fn writeWalDeleteEpisodePlaybackProgress(self: *LogsStorage, username: []const u8, episode_id: i64) void {
        var buf: [256]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.delete_episode_playback_progress);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        std.mem.writeInt(i64, buf[pos..][0..8], episode_id, .little);
        pos += 8;
        self.writeWalRecord(buf[0..pos]);
    }

    fn writeWalLogPlaybackEvent(self: *LogsStorage, id: i64, username: []const u8, movie_id: i64, event_type: []const u8, position: f64, timestamp: i64) void {
        var buf: [512]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        const ev_len: u16 = @intCast(@min(event_type.len, 100));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.log_playback_event);
        pos += 1;
        std.mem.writeInt(i64, buf[pos..][0..8], id, .little);
        pos += 8;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        std.mem.writeInt(i64, buf[pos..][0..8], movie_id, .little);
        pos += 8;
        std.mem.writeInt(u16, buf[pos..][0..2], ev_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + ev_len], event_type[0..ev_len]);
        pos += ev_len;
        std.mem.writeInt(u64, buf[pos..][0..8], @as(u64, @bitCast(position)), .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], timestamp, .little);
        pos += 8;
        self.writeWalRecord(buf[0..pos]);
    }

    fn writeWalLogEpisodePlaybackEvent(self: *LogsStorage, id: i64, username: []const u8, episode_id: i64, event_type: []const u8, position: f64, timestamp: i64) void {
        var buf: [512]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        const ev_len: u16 = @intCast(@min(event_type.len, 100));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.log_episode_playback_event);
        pos += 1;
        std.mem.writeInt(i64, buf[pos..][0..8], id, .little);
        pos += 8;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        std.mem.writeInt(i64, buf[pos..][0..8], episode_id, .little);
        pos += 8;
        std.mem.writeInt(u16, buf[pos..][0..2], ev_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + ev_len], event_type[0..ev_len]);
        pos += ev_len;
        std.mem.writeInt(u64, buf[pos..][0..8], @as(u64, @bitCast(position)), .little);
        pos += 8;
        std.mem.writeInt(i64, buf[pos..][0..8], timestamp, .little);
        pos += 8;
        self.writeWalRecord(buf[0..pos]);
    }

    fn writeWalLogLoginAttempt(self: *LogsStorage, id: i64, username: []const u8, status: []const u8, ip_address: []const u8, timestamp: i64) void {
        var buf: [512]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        const st_len: u16 = @intCast(@min(status.len, 50));
        const ip_len: u16 = @intCast(@min(ip_address.len, 100));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.log_login_attempt);
        pos += 1;
        std.mem.writeInt(i64, buf[pos..][0..8], id, .little);
        pos += 8;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        std.mem.writeInt(u16, buf[pos..][0..2], st_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + st_len], status[0..st_len]);
        pos += st_len;
        std.mem.writeInt(u16, buf[pos..][0..2], ip_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + ip_len], ip_address[0..ip_len]);
        pos += ip_len;
        std.mem.writeInt(i64, buf[pos..][0..8], timestamp, .little);
        pos += 8;
        self.writeWalRecord(buf[0..pos]);
    }

    fn writeWalClearFailedLogins(self: *LogsStorage, username: []const u8) void {
        var buf: [256]u8 = undefined;
        const u_len: u16 = @intCast(@min(username.len, 200));
        var pos: usize = 0;
        buf[pos] = @intFromEnum(WalOpcode.clear_failed_logins);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], u_len, .little);
        pos += 2;
        @memcpy(buf[pos .. pos + u_len], username[0..u_len]);
        pos += u_len;
        self.writeWalRecord(buf[0..pos]);
    }

    fn applyWalPayload(self: *LogsStorage, payload: []const u8) !void {
        if (payload.len < 1) return;
        const raw_op = payload[0];
        const op: WalOpcode = @enumFromInt(raw_op);
        switch (op) {
            .save_playback_progress => {
                if (payload.len < 3) return;
                const u_len = std.mem.readInt(u16, payload[1..3], .little);
                if (payload.len < 3 + u_len + 32) return;
                const username = payload[3 .. 3 + u_len];
                var pos: usize = 3 + u_len;
                const movie_id = std.mem.readInt(i64, payload[pos..][0..8], .little);
                pos += 8;
                const position: f64 = @bitCast(std.mem.readInt(u64, payload[pos..][0..8], .little));
                pos += 8;
                const duration: f64 = @bitCast(std.mem.readInt(u64, payload[pos..][0..8], .little));
                pos += 8;
                const updated_at = std.mem.readInt(i64, payload[pos..][0..8], .little);

                const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ username, movie_id });
                if (self.playback_progress.getPtr(key)) |ptr| {
                    ptr.position = position;
                    ptr.duration = duration;
                    ptr.updated_at = updated_at;
                    self.allocator.free(key);
                } else {
                    const pp = schema.PlaybackProgress{
                        .username = try self.allocator.dupe(u8, username),
                        .movie_id = movie_id,
                        .position = position,
                        .duration = duration,
                        .updated_at = updated_at,
                    };
                    try self.playback_progress.put(key, pp);
                }
            },
            .save_episode_playback_progress => {
                if (payload.len < 3) return;
                const u_len = std.mem.readInt(u16, payload[1..3], .little);
                if (payload.len < 3 + u_len + 32) return;
                const username = payload[3 .. 3 + u_len];
                var pos: usize = 3 + u_len;
                const episode_id = std.mem.readInt(i64, payload[pos..][0..8], .little);
                pos += 8;
                const position: f64 = @bitCast(std.mem.readInt(u64, payload[pos..][0..8], .little));
                pos += 8;
                const duration: f64 = @bitCast(std.mem.readInt(u64, payload[pos..][0..8], .little));
                pos += 8;
                const updated_at = std.mem.readInt(i64, payload[pos..][0..8], .little);

                const key = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ username, episode_id });
                if (self.episode_playback_progress.getPtr(key)) |ptr| {
                    ptr.position = position;
                    ptr.duration = duration;
                    ptr.updated_at = updated_at;
                    self.allocator.free(key);
                } else {
                    const epp = schema.EpisodePlaybackProgress{
                        .username = try self.allocator.dupe(u8, username),
                        .episode_id = episode_id,
                        .position = position,
                        .duration = duration,
                        .updated_at = updated_at,
                    };
                    try self.episode_playback_progress.put(key, epp);
                }
            },
            .delete_playback_progress => {
                if (payload.len < 3) return;
                const u_len = std.mem.readInt(u16, payload[1..3], .little);
                if (payload.len < 3 + u_len + 8) return;
                const username = payload[3 .. 3 + u_len];
                const movie_id = std.mem.readInt(i64, payload[3 + u_len ..][0..8], .little);

                var key_buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ username, movie_id }) catch return;
                if (self.playback_progress.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    var val = kv.value;
                    val.deinit(self.allocator);
                }
            },
            .delete_episode_playback_progress => {
                if (payload.len < 3) return;
                const u_len = std.mem.readInt(u16, payload[1..3], .little);
                if (payload.len < 3 + u_len + 8) return;
                const username = payload[3 .. 3 + u_len];
                const episode_id = std.mem.readInt(i64, payload[3 + u_len ..][0..8], .little);

                var key_buf: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&key_buf, "{s}:{d}", .{ username, episode_id }) catch return;
                if (self.episode_playback_progress.fetchRemove(key)) |kv| {
                    self.allocator.free(kv.key);
                    var val = kv.value;
                    val.deinit(self.allocator);
                }
            },
            .log_playback_event => {
                if (payload.len < 1 + 8 + 2) return;
                var pos: usize = 1;
                const id = std.mem.readInt(i64, payload[pos..][0..8], .little);
                pos += 8;
                const u_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
                pos += 2;
                if (pos + u_len + 8 + 2 > payload.len) return;
                const username = payload[pos .. pos + u_len];
                pos += u_len;
                const movie_id = std.mem.readInt(i64, payload[pos..][0..8], .little);
                pos += 8;
                const ev_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
                pos += 2;
                if (pos + ev_len + 16 > payload.len) return;
                const event_type = payload[pos .. pos + ev_len];
                pos += ev_len;
                const position: f64 = @bitCast(std.mem.readInt(u64, payload[pos..][0..8], .little));
                pos += 8;
                const timestamp = std.mem.readInt(i64, payload[pos..][0..8], .little);

                if (id >= self.next_playback_log_id) self.next_playback_log_id = id + 1;
                const log = schema.PlaybackLog{
                    .id = id,
                    .username = try self.allocator.dupe(u8, username),
                    .movie_id = movie_id,
                    .event_type = try self.allocator.dupe(u8, event_type),
                    .position = position,
                    .timestamp = timestamp,
                };
                try self.playback_logs.append(self.allocator, log);
            },
            .log_episode_playback_event => {
                if (payload.len < 1 + 8 + 2) return;
                var pos: usize = 1;
                const id = std.mem.readInt(i64, payload[pos..][0..8], .little);
                pos += 8;
                const u_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
                pos += 2;
                if (pos + u_len + 8 + 2 > payload.len) return;
                const username = payload[pos .. pos + u_len];
                pos += u_len;
                const episode_id = std.mem.readInt(i64, payload[pos..][0..8], .little);
                pos += 8;
                const ev_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
                pos += 2;
                if (pos + ev_len + 16 > payload.len) return;
                const event_type = payload[pos .. pos + ev_len];
                pos += ev_len;
                const position: f64 = @bitCast(std.mem.readInt(u64, payload[pos..][0..8], .little));
                pos += 8;
                const timestamp = std.mem.readInt(i64, payload[pos..][0..8], .little);

                if (id >= self.next_episode_log_id) self.next_episode_log_id = id + 1;
                const log = schema.EpisodePlaybackLog{
                    .id = id,
                    .username = try self.allocator.dupe(u8, username),
                    .episode_id = episode_id,
                    .event_type = try self.allocator.dupe(u8, event_type),
                    .position = position,
                    .timestamp = timestamp,
                };
                try self.episode_playback_logs.append(self.allocator, log);
            },
            .log_login_attempt => {
                if (payload.len < 1 + 8 + 2) return;
                var pos: usize = 1;
                const id = std.mem.readInt(i64, payload[pos..][0..8], .little);
                pos += 8;
                const u_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
                pos += 2;
                if (pos + u_len + 2 > payload.len) return;
                const username = payload[pos .. pos + u_len];
                pos += u_len;
                const st_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
                pos += 2;
                if (pos + st_len + 2 > payload.len) return;
                const status = payload[pos .. pos + st_len];
                pos += st_len;
                const ip_len = std.mem.readInt(u16, payload[pos..][0..2], .little);
                pos += 2;
                if (pos + ip_len + 8 > payload.len) return;
                const ip_address = payload[pos .. pos + ip_len];
                pos += ip_len;
                const timestamp = std.mem.readInt(i64, payload[pos..][0..8], .little);

                if (id >= self.next_login_log_id) self.next_login_log_id = id + 1;
                const log = schema.LoginLog{
                    .id = id,
                    .username = try self.allocator.dupe(u8, username),
                    .status = try self.allocator.dupe(u8, status),
                    .ip_address = try self.allocator.dupe(u8, ip_address),
                    .timestamp = timestamp,
                };
                try self.login_logs.append(self.allocator, log);
            },
            .clear_failed_logins => {
                if (payload.len < 3) return;
                const u_len = std.mem.readInt(u16, payload[1..3], .little);
                if (payload.len < 3 + u_len) return;
                const username = payload[3 .. 3 + u_len];

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
            },
            _ => return,
        }
    }

    fn replayWal(self: *LogsStorage) !usize {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.wal_path, self.allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
            if (err == error.FileNotFound) return 0;
            return err;
        };
        defer self.allocator.free(bytes);

        if (bytes.len < 12) return 0;

        var offset: usize = 0;
        var replayed_count: usize = 0;

        while (offset + 12 <= bytes.len) {
            const magic = bytes[offset..][0..4];
            if (!std.mem.eql(u8, magic, "WAL1")) {
                std.debug.print("LogsStorage: WAL magic mismatch at offset {d}, stopping replay\n", .{offset});
                break;
            }

            const payload_len = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
            const expected_crc = std.mem.readInt(u32, bytes[offset + 8 ..][0..4], .little);

            if (offset + 12 + payload_len > bytes.len) {
                std.debug.print("LogsStorage: truncated WAL record at offset {d} (expected {d} bytes, remaining {d}), stopping replay\n", .{
                    offset, payload_len, bytes.len - (offset + 12),
                });
                break;
            }

            const payload = bytes[offset + 12 .. offset + 12 + payload_len];
            const actual_crc = std.hash.Crc32.hash(payload);
            if (actual_crc != expected_crc) {
                std.debug.print("LogsStorage: WAL record CRC32 mismatch at offset {d}, stopping replay\n", .{offset});
                break;
            }

            try self.applyWalPayload(payload);
            replayed_count += 1;
            offset += 12 + payload_len;
        }

        return replayed_count;
    }

    fn loadSnapshot(self: *LogsStorage) !bool {
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

    pub fn load(self: *LogsStorage) !bool {
        self.writeLock();
        defer self.writeUnlock();

        const loaded_snap = self.loadSnapshot() catch |err| blk: {
            if (err == error.FileNotFound) break :blk false;
            std.debug.print("LogsStorage: error loading snapshot {s}: {}\n", .{ self.file_path, err });
            break :blk false;
        };

        const replayed_count = self.replayWal() catch |err| blk: {
            std.debug.print("LogsStorage: error replaying WAL {s}: {}\n", .{ self.wal_path, err });
            break :blk 0;
        };

        if (replayed_count > 0) {
            self.snapshotLocked() catch {};
        }

        return loaded_snap or (replayed_count > 0);
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
        self.writeWalLogLoginAttempt(id, username, status, ip_address, log.timestamp);
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
        self.writeWalClearFailedLogins(username);
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
        self.writeWalLogPlaybackEvent(id, username, movie_id, event_type, position, log.timestamp);
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
        self.writeWalSavePlaybackProgress(username, movie_id, position, duration, current_time);
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
        self.writeWalDeletePlaybackProgress(username, movie_id);
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
        self.writeWalLogEpisodePlaybackEvent(id, username, episode_id, event_type, position, log.timestamp);
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
        self.writeWalSaveEpisodePlaybackProgress(username, episode_id, position, duration, current_time);
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
        self.writeWalDeleteEpisodePlaybackProgress(username, episode_id);
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
