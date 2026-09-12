const std = @import("std");
const db_mod = @import("db.zig");
const engine = @import("../storage/engine.zig");
const logs_engine = @import("../storage/logs_engine.zig");
const schema = @import("../storage/schema.zig");

pub const TimeRange = enum {
    d7,
    d30,
    d90,
    all,

    pub fn fromString(str: []const u8) TimeRange {
        if (std.mem.eql(u8, str, "7d")) return .d7;
        if (std.mem.eql(u8, str, "30d")) return .d30;
        if (std.mem.eql(u8, str, "90d")) return .d90;
        if (std.mem.eql(u8, str, "all")) return .all;
        return .d30;
    }

    pub fn asString(self: TimeRange) []const u8 {
        return switch (self) {
            .d7 => "7d",
            .d30 => "30d",
            .d90 => "90d",
            .all => "all",
        };
    }

    pub fn getStartTimestamp(self: TimeRange, now_ts: i64) i64 {
        return switch (self) {
            .d7 => now_ts - 7 * 86400,
            .d30 => now_ts - 30 * 86400,
            .d90 => now_ts - 90 * 86400,
            .all => 0,
        };
    }
};

pub const SortOrder = enum {
    watch_time,
    play_count,

    pub fn fromString(str: []const u8) SortOrder {
        if (std.mem.eql(u8, str, "plays")) return .play_count;
        return .watch_time;
    }

    pub fn asString(self: SortOrder) []const u8 {
        return switch (self) {
            .watch_time => "time",
            .play_count => "plays",
        };
    }
};

pub const AnalyticsOverview = struct {
    total_watch_seconds: u64 = 0,
    total_plays: u64 = 0,
    active_viewers: u64 = 0,
    peak_hour: u8 = 0,
    total_movies_watched: u64 = 0,
    total_episodes_watched: u64 = 0,
};

pub const DailyTrendPoint = struct {
    day_epoch: i64,
    date_str: [10]u8, // "YYYY-MM-DD"
    seconds_watched: u64 = 0,
    play_count: u64 = 0,
};

pub const WatchedMovieItem = struct {
    movie_id: i64,
    title: []const u8,
    poster_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    seconds_watched: u64 = 0,
    play_count: u64 = 0,
};

pub const WatchedShowItem = struct {
    show_id: i64,
    title: []const u8,
    poster_path: ?[]const u8 = null,
    seconds_watched: u64 = 0,
    episodes_played: u64 = 0,
    play_count: u64 = 0,
};

pub const UserActivityItem = struct {
    username: []const u8,
    seconds_watched: u64 = 0,
    play_count: u64 = 0,
    last_active: i64 = 0,
};

pub const AnalyticsReport = struct {
    arena: ?std.heap.ArenaAllocator = null,
    range: TimeRange,
    overview: AnalyticsOverview,
    daily_trend: []DailyTrendPoint,
    hourly_distribution: [24]u64,
    top_movies: []WatchedMovieItem,
    top_shows: []WatchedShowItem,
    user_activity: []UserActivityItem,

    pub fn deinit(self: *AnalyticsReport) void {
        if (self.arena) |*a| {
            a.deinit();
            self.arena = null;
        }
    }
};

/// Converts epoch seconds to "YYYY-MM-DD" string.
pub fn epochToDateStr(ts: i64) [10]u8 {
    var buf: [10]u8 = "1970-01-01".*;
    if (ts < 0) return buf;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch {};
    return buf;
}

const MediaAgg = struct {
    seconds: u64 = 0,
    plays: u64 = 0,
};

const ShowAgg = struct {
    seconds: u64 = 0,
    plays: u64 = 0,
    episodes: std.AutoHashMap(i64, void),
};

const UserAgg = struct {
    seconds: u64 = 0,
    plays: u64 = 0,
    last_active: i64 = 0,
};

fn movieLessThan(order: SortOrder, a: WatchedMovieItem, b: WatchedMovieItem) bool {
    return switch (order) {
        .watch_time => if (a.seconds_watched != b.seconds_watched)
            a.seconds_watched > b.seconds_watched
        else
            a.play_count > b.play_count,
        .play_count => if (a.play_count != b.play_count)
            a.play_count > b.play_count
        else
            a.seconds_watched > b.seconds_watched,
    };
}

fn showLessThan(order: SortOrder, a: WatchedShowItem, b: WatchedShowItem) bool {
    return switch (order) {
        .watch_time => if (a.seconds_watched != b.seconds_watched)
            a.seconds_watched > b.seconds_watched
        else
            a.play_count > b.play_count,
        .play_count => if (a.play_count != b.play_count)
            a.play_count > b.play_count
        else
            a.seconds_watched > b.seconds_watched,
    };
}

fn userLessThan(_: void, a: UserActivityItem, b: UserActivityItem) bool {
    if (a.seconds_watched != b.seconds_watched) {
        return a.seconds_watched > b.seconds_watched;
    }
    return a.play_count > b.play_count;
}

fn dailyLessThan(_: void, a: DailyTrendPoint, b: DailyTrendPoint) bool {
    return a.day_epoch < b.day_epoch;
}

/// Computes a complete analytics report across catalog and telemetry storage.
pub fn computeReport(
    backing_allocator: std.mem.Allocator,
    catalog: *engine.SratimStorage,
    logs: *logs_engine.LogsStorage,
    range: TimeRange,
    sort_order: SortOrder,
    limit: usize,
) !AnalyticsReport {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    // Acquire shared read locks on both stores
    catalog.rwlock.lockSharedUncancelable(catalog.io);
    defer catalog.rwlock.unlockShared(catalog.io);

    logs.rwlock.lockSharedUncancelable(logs.io);
    defer logs.rwlock.unlockShared(logs.io);

    const now_ts = std.Io.Timestamp.now(logs.io, .real).toSeconds();
    const start_ts = range.getStartTimestamp(now_ts);

    var overview = AnalyticsOverview{};
    var hourly_distribution: [24]u64 = [_]u64{0} ** 24;

    var active_viewers_set = std.StringHashMap(void).init(aa);
    var movie_stats = std.AutoHashMap(i64, MediaAgg).init(aa);
    var show_stats = std.AutoHashMap(i64, ShowAgg).init(aa);
    var user_stats = std.StringHashMap(UserAgg).init(aa);
    var daily_map = std.AutoHashMap(i64, DailyTrendPoint).init(aa);

    // Pre-populate daily trend for fixed time ranges to provide a continuous curve
    if (range != .all and start_ts > 0) {
        const start_day = @divFloor(start_ts, 86400);
        const current_day = @divFloor(now_ts, 86400);
        var d = start_day;
        while (d <= current_day) : (d += 1) {
            try daily_map.put(d, .{
                .day_epoch = d,
                .date_str = epochToDateStr(d * 86400),
                .seconds_watched = 0,
                .play_count = 0,
            });
        }
    }

    // 1. Traverse movie playback logs
    for (logs.playback_logs.items) |log| {
        if (log.timestamp < start_ts) continue;

        try active_viewers_set.put(log.username, {});

        const hour = @as(usize, @intCast(@mod(@divFloor(log.timestamp, 3600), 24)));
        const day_epoch = @divFloor(log.timestamp, 86400);

        var daily_entry = try daily_map.getOrPut(day_epoch);
        if (!daily_entry.found_existing) {
            daily_entry.value_ptr.* = .{
                .day_epoch = day_epoch,
                .date_str = epochToDateStr(day_epoch * 86400),
                .seconds_watched = 0,
                .play_count = 0,
            };
        }

        var m_entry = try movie_stats.getOrPut(log.movie_id);
        if (!m_entry.found_existing) {
            m_entry.value_ptr.* = .{};
        }

        var u_entry = try user_stats.getOrPut(log.username);
        if (!u_entry.found_existing) {
            u_entry.value_ptr.* = .{ .last_active = log.timestamp };
        }
        if (log.timestamp > u_entry.value_ptr.last_active) {
            u_entry.value_ptr.last_active = log.timestamp;
        }

        if (std.mem.eql(u8, log.event_type, "progress")) {
            overview.total_watch_seconds += 10;
            hourly_distribution[hour] += 10;
            daily_entry.value_ptr.seconds_watched += 10;
            m_entry.value_ptr.seconds += 10;
            u_entry.value_ptr.seconds += 10;
        } else if (std.mem.eql(u8, log.event_type, "start")) {
            overview.total_plays += 1;
            daily_entry.value_ptr.play_count += 1;
            m_entry.value_ptr.plays += 1;
            u_entry.value_ptr.plays += 1;
        }
    }

    // 2. Traverse episode playback logs
    for (logs.episode_playback_logs.items) |log| {
        if (log.timestamp < start_ts) continue;

        try active_viewers_set.put(log.username, {});

        const hour = @as(usize, @intCast(@mod(@divFloor(log.timestamp, 3600), 24)));
        const day_epoch = @divFloor(log.timestamp, 86400);

        var daily_entry = try daily_map.getOrPut(day_epoch);
        if (!daily_entry.found_existing) {
            daily_entry.value_ptr.* = .{
                .day_epoch = day_epoch,
                .date_str = epochToDateStr(day_epoch * 86400),
                .seconds_watched = 0,
                .play_count = 0,
            };
        }

        var u_entry = try user_stats.getOrPut(log.username);
        if (!u_entry.found_existing) {
            u_entry.value_ptr.* = .{ .last_active = log.timestamp };
        }
        if (log.timestamp > u_entry.value_ptr.last_active) {
            u_entry.value_ptr.last_active = log.timestamp;
        }

        // Identify show_id from catalog
        var show_id_opt: ?i64 = null;
        if (catalog.episodes.get(log.episode_id)) |ep| {
            show_id_opt = ep.show_id;
        }

        if (std.mem.eql(u8, log.event_type, "progress")) {
            overview.total_watch_seconds += 10;
            hourly_distribution[hour] += 10;
            daily_entry.value_ptr.seconds_watched += 10;
            u_entry.value_ptr.seconds += 10;

            if (show_id_opt) |sid| {
                var sh_entry = try show_stats.getOrPut(sid);
                if (!sh_entry.found_existing) {
                    sh_entry.value_ptr.* = .{ .episodes = std.AutoHashMap(i64, void).init(aa) };
                }
                sh_entry.value_ptr.seconds += 10;
                try sh_entry.value_ptr.episodes.put(log.episode_id, {});
            }
        } else if (std.mem.eql(u8, log.event_type, "start")) {
            overview.total_plays += 1;
            daily_entry.value_ptr.play_count += 1;
            u_entry.value_ptr.plays += 1;

            if (show_id_opt) |sid| {
                var sh_entry = try show_stats.getOrPut(sid);
                if (!sh_entry.found_existing) {
                    sh_entry.value_ptr.* = .{ .episodes = std.AutoHashMap(i64, void).init(aa) };
                }
                sh_entry.value_ptr.plays += 1;
                try sh_entry.value_ptr.episodes.put(log.episode_id, {});
            }
        }
    }

    overview.active_viewers = active_viewers_set.count();
    overview.total_movies_watched = movie_stats.count();
    overview.total_episodes_watched = show_stats.count();

    // Determine peak hour
    var max_hourly: u64 = 0;
    var peak_h: u8 = 0;
    for (hourly_distribution, 0..) |val, h| {
        if (val > max_hourly) {
            max_hourly = val;
            peak_h = @intCast(h);
        }
    }
    overview.peak_hour = peak_h;

    // Daily trend slice
    var daily_list = std.ArrayList(DailyTrendPoint).empty;
    var d_it = daily_map.valueIterator();
    while (d_it.next()) |val| {
        try daily_list.append(aa, val.*);
    }
    std.mem.sort(DailyTrendPoint, daily_list.items, {}, dailyLessThan);

    // Build top movies list
    var movies_list = std.ArrayList(WatchedMovieItem).empty;
    var m_it = movie_stats.iterator();
    while (m_it.next()) |entry| {
        const mid = entry.key_ptr.*;
        const stats = entry.value_ptr.*;

        var title: []const u8 = "Unknown Movie";
        var poster_path: ?[]const u8 = null;
        var release_date: ?[]const u8 = null;

        if (catalog.movies.get(mid)) |m| {
            title = if (m.title) |t| t else m.clean_name;
            poster_path = m.poster_path;
            release_date = m.release_date;
        }

        try movies_list.append(aa, .{
            .movie_id = mid,
            .title = try aa.dupe(u8, title),
            .poster_path = if (poster_path) |p| try aa.dupe(u8, p) else null,
            .release_date = if (release_date) |r| try aa.dupe(u8, r) else null,
            .seconds_watched = stats.seconds,
            .play_count = stats.plays,
        });
    }
    std.mem.sort(WatchedMovieItem, movies_list.items, sort_order, movieLessThan);
    const movie_count = @min(limit, movies_list.items.len);
    const top_movies = movies_list.items[0..movie_count];

    // Build top shows list
    var shows_list = std.ArrayList(WatchedShowItem).empty;
    var s_it = show_stats.iterator();
    while (s_it.next()) |entry| {
        const sid = entry.key_ptr.*;
        const stats = entry.value_ptr.*;

        var title: []const u8 = "Unknown Show";
        var poster_path: ?[]const u8 = null;

        if (catalog.shows.get(sid)) |sh| {
            title = sh.title;
            poster_path = sh.poster_path;
        }

        try shows_list.append(aa, .{
            .show_id = sid,
            .title = try aa.dupe(u8, title),
            .poster_path = if (poster_path) |p| try aa.dupe(u8, p) else null,
            .seconds_watched = stats.seconds,
            .episodes_played = stats.episodes.count(),
            .play_count = stats.plays,
        });
    }
    std.mem.sort(WatchedShowItem, shows_list.items, sort_order, showLessThan);
    const show_count = @min(limit, shows_list.items.len);
    const top_shows = shows_list.items[0..show_count];

    // Build user activity list
    var users_list = std.ArrayList(UserActivityItem).empty;
    var u_it = user_stats.iterator();
    while (u_it.next()) |entry| {
        try users_list.append(aa, .{
            .username = try aa.dupe(u8, entry.key_ptr.*),
            .seconds_watched = entry.value_ptr.seconds,
            .play_count = entry.value_ptr.plays,
            .last_active = entry.value_ptr.last_active,
        });
    }
    std.mem.sort(UserActivityItem, users_list.items, {}, userLessThan);
    const user_count = @min(limit, users_list.items.len);
    const top_users = users_list.items[0..user_count];

    return .{
        .arena = arena,
        .range = range,
        .overview = overview,
        .daily_trend = daily_list.items,
        .hourly_distribution = hourly_distribution,
        .top_movies = top_movies,
        .top_shows = top_shows,
        .user_activity = top_users,
    };
}

// =============================================================================
// Unit Tests
// =============================================================================

test "analytics: empty logs report" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_analytics_cat.json", "tmp/test_analytics_cat.wal", "tmp/test_analytics_cat_persons");
    defer cat.deinit();

    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_analytics_logs.json", "tmp/test_analytics_logs.wal");
    defer logs.deinit();

    var report = try computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    try std.testing.expectEqual(@as(u64, 0), report.overview.total_watch_seconds);
    try std.testing.expectEqual(@as(u64, 0), report.overview.total_plays);
    try std.testing.expectEqual(@as(u64, 0), report.overview.active_viewers);
    try std.testing.expectEqual(@as(usize, 0), report.top_movies.len);
    try std.testing.expectEqual(@as(usize, 0), report.top_shows.len);
    try std.testing.expectEqual(@as(usize, 0), report.user_activity.len);
    try std.testing.expect(report.daily_trend.len >= 30);
}

test "analytics: watch time aggregation and leaderboard sorting" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_analytics_cat2.json", "tmp/test_analytics_cat2.wal", "tmp/test_analytics_cat2_persons");
    defer cat.deinit();

    // Seed movies
    _ = try cat.addOrUpdateMovie(.{
        .id = 1,
        .library_id = 1,
        .file_path = "/path/movie1.mkv",
        .clean_name = "Movie One",
        .title = "Movie One",
        .file_size = 1000,
    });
    _ = try cat.addOrUpdateMovie(.{
        .id = 2,
        .library_id = 1,
        .file_path = "/path/movie2.mkv",
        .clean_name = "Movie Two",
        .title = "Movie Two",
        .file_size = 2000,
    });

    // Seed show and episode
    const show_id = try cat.addOrUpdateShow(.{
        .id = 10,
        .library_id = 2,
        .path = "/path/Show",
        .title = "Epic Series",
    });
    const ep_id = try cat.addOrUpdateEpisode(.{
        .id = 101,
        .show_id = show_id,
        .file_path = "/path/Show/S01E01.mkv",
        .season = 1,
        .episode = 1,
        .file_size = 500,
    });

    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_analytics_logs2.json", "tmp/test_analytics_logs2.wal");
    defer logs.deinit();

    // Alice watches Movie 1: 1 start, 5 progress (50s)
    try logs.logPlaybackEvent("alice", 1, "start", 0.0);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try logs.logPlaybackEvent("alice", 1, "progress", @floatFromInt((i + 1) * 10));
    }

    // Bob watches Movie 1: 1 start, 3 progress (30s)
    try logs.logPlaybackEvent("bob", 1, "start", 0.0);
    i = 0;
    while (i < 3) : (i += 1) {
        try logs.logPlaybackEvent("bob", 1, "progress", @floatFromInt((i + 1) * 10));
    }

    // Alice watches Movie 2: 1 start, 10 progress (100s)
    try logs.logPlaybackEvent("alice", 2, "start", 0.0);
    i = 0;
    while (i < 10) : (i += 1) {
        try logs.logPlaybackEvent("alice", 2, "progress", @floatFromInt((i + 1) * 10));
    }

    // Charlie watches Show 1 episode 1: 1 start, 8 progress (80s)
    try logs.logEpisodePlaybackEvent("charlie", ep_id, "start", 0.0);
    i = 0;
    while (i < 8) : (i += 1) {
        try logs.logEpisodePlaybackEvent("charlie", ep_id, "progress", @floatFromInt((i + 1) * 10));
    }

    var report = try computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    // Total watch seconds = 50 + 30 + 100 + 80 = 260
    try std.testing.expectEqual(@as(u64, 260), report.overview.total_watch_seconds);
    // Total plays = 1 + 1 + 1 + 1 = 4
    try std.testing.expectEqual(@as(u64, 4), report.overview.total_plays);
    // Active viewers = alice, bob, charlie = 3
    try std.testing.expectEqual(@as(u64, 3), report.overview.active_viewers);

    // Top movies: Movie 2 has 100s, Movie 1 has 80s
    try std.testing.expectEqual(@as(usize, 2), report.top_movies.len);
    try std.testing.expectEqual(@as(i64, 2), report.top_movies[0].movie_id);
    try std.testing.expectEqual(@as(u64, 100), report.top_movies[0].seconds_watched);
    try std.testing.expectEqual(@as(i64, 1), report.top_movies[1].movie_id);
    try std.testing.expectEqual(@as(u64, 80), report.top_movies[1].seconds_watched);

    // Top shows: Show 1 has 80s
    try std.testing.expectEqual(@as(usize, 1), report.top_shows.len);
    try std.testing.expectEqual(show_id, report.top_shows[0].show_id);
    try std.testing.expectEqual(@as(u64, 80), report.top_shows[0].seconds_watched);

    // Top users: Alice has 150s (50 + 100), Charlie has 80s, Bob has 30s
    try std.testing.expectEqual(@as(usize, 3), report.user_activity.len);
    try std.testing.expectEqualStrings("alice", report.user_activity[0].username);
    try std.testing.expectEqual(@as(u64, 150), report.user_activity[0].seconds_watched);
    try std.testing.expectEqualStrings("charlie", report.user_activity[1].username);
    try std.testing.expectEqual(@as(u64, 80), report.user_activity[1].seconds_watched);
    try std.testing.expectEqualStrings("bob", report.user_activity[2].username);
    try std.testing.expectEqual(@as(u64, 30), report.user_activity[2].seconds_watched);
}
