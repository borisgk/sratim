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

pub const WatchedPersonItem = struct {
    person_id: i64,
    name: []const u8,
    profile_path: ?[]const u8 = null,
    known_for_department: ?[]const u8 = null,
    seconds_watched: u64 = 0,
    play_count: u64 = 0,
    titles_count: usize = 0,
    top_role: ?[]const u8 = null,
};

pub const UbiquitousActor = struct {
    person_id: i64,
    name: []const u8,
    profile_path: ?[]const u8 = null,
    title_count: usize = 0,
    sample_titles: []const []const u8 = &.{},
};

pub const CollaboratorPair = struct {
    person_a_id: i64,
    person_a_name: []const u8,
    person_a_role: []const u8, // "Director" or "Actor"
    person_b_id: i64,
    person_b_name: []const u8,
    person_b_role: []const u8, // "Actor"
    shared_title_count: usize = 0,
    shared_titles: []const []const u8 = &.{},
};

pub const TitleCrossover = struct {
    title_a_id: i64,
    title_a_name: []const u8,
    title_a_is_show: bool,
    title_b_id: i64,
    title_b_name: []const u8,
    title_b_is_show: bool,
    shared_actor_count: usize = 0,
    shared_actors: []const []const u8 = &.{},
};

pub const EraPoint = struct {
    decade: u16, // 1960 for pre-1970, 1970, 1980, 1990, 2000, 2010, 2020
    label: []const u8,
    seconds_watched: u64 = 0,
    title_count: usize = 0,
    percent: u8 = 0,
};

pub const AnalyticsTrivia = struct {
    ubiquitous_actor: ?UbiquitousActor = null,
    collaborators: ?CollaboratorPair = null,
    crossover: ?TitleCrossover = null,
    eras: []EraPoint = &.{},
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
    top_actors: []WatchedPersonItem = &.{},
    top_directors: []WatchedPersonItem = &.{},
    trivia: AnalyticsTrivia = .{},
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

fn personLessThan(order: SortOrder, a: WatchedPersonItem, b: WatchedPersonItem) bool {
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

pub fn parseYear(date_str: ?[]const u8) ?u16 {
    if (date_str) |s| {
        if (s.len >= 4) {
            return std.fmt.parseInt(u16, s[0..4], 10) catch null;
        }
    }
    return null;
}

pub fn findYearInString(s: []const u8) ?u16 {
    if (s.len < 4) return null;
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 1) {
        const slice = s[i .. i + 4];
        if (slice[0] == '1' or slice[0] == '2') {
            if (std.fmt.parseInt(u16, slice, 10)) |val| {
                if (val >= 1920 and val <= 2035) {
                    const prev_ok = (i == 0) or !std.ascii.isDigit(s[i - 1]);
                    const next_ok = (i + 4 == s.len) or !std.ascii.isDigit(s[i + 4]);
                    if (prev_ok and next_ok) return val;
                }
            } else |_| {}
        }
    }
    return null;
}

fn yearToDecade(year: u16) u16 {
    if (year < 1970) return 1960;
    if (year < 1980) return 1970;
    if (year < 1990) return 1980;
    if (year < 2000) return 1990;
    if (year < 2010) return 2000;
    if (year < 2020) return 2010;
    return 2020;
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

    // 3. Build top actors and top directors lists
    const PersonAgg = struct {
        person_id: i64,
        name: []const u8,
        profile_path: ?[]const u8 = null,
        known_for_department: ?[]const u8 = null,
        seconds: u64 = 0,
        plays: u64 = 0,
        titles_count: usize = 0,
        top_role: ?[]const u8 = null,
    };

    const PersonMediaKey = struct {
        person_id: i64,
        media_id: i64,
        is_show: bool,
    };
    var actor_seen = std.AutoHashMap(PersonMediaKey, void).init(aa);
    var director_seen = std.AutoHashMap(PersonMediaKey, void).init(aa);

    var actor_stats = std.AutoHashMap(i64, PersonAgg).init(aa);
    var director_stats = std.AutoHashMap(i64, PersonAgg).init(aa);

    // Process movie credits for watched movies
    var m_cr_it = catalog.movie_credits.valueIterator();
    while (m_cr_it.next()) |cr| {
        if (movie_stats.get(cr.movie_id)) |stats| {
            if (stats.seconds > 0 or stats.plays > 0) {
                if (cr.is_cast) {
                    const key = PersonMediaKey{ .person_id = cr.person_id, .media_id = cr.movie_id, .is_show = false };
                    if (!actor_seen.contains(key)) {
                        try actor_seen.put(key, {});
                        var entry = try actor_stats.getOrPut(cr.person_id);
                        if (!entry.found_existing) {
                            var prof: ?[]const u8 = cr.profile_path;
                            if (prof == null) {
                                if (catalog.people.get(cr.person_id)) |p| prof = p.profile_path;
                            }
                            entry.value_ptr.* = .{
                                .person_id = cr.person_id,
                                .name = cr.name,
                                .profile_path = prof,
                                .known_for_department = "Acting",
                                .seconds = 0,
                                .plays = 0,
                                .titles_count = 0,
                                .top_role = cr.character,
                            };
                        }
                        entry.value_ptr.seconds += stats.seconds;
                        entry.value_ptr.plays += stats.plays;
                        entry.value_ptr.titles_count += 1;
                        if (entry.value_ptr.profile_path == null and cr.profile_path != null) {
                            entry.value_ptr.profile_path = cr.profile_path;
                        }
                    }
                }

                const is_dir = !cr.is_cast and (std.mem.eql(u8, cr.department, "Directing") or (cr.job != null and std.mem.indexOf(u8, cr.job.?, "Director") != null));
                if (is_dir) {
                    const key = PersonMediaKey{ .person_id = cr.person_id, .media_id = cr.movie_id, .is_show = false };
                    if (!director_seen.contains(key)) {
                        try director_seen.put(key, {});
                        var entry = try director_stats.getOrPut(cr.person_id);
                        if (!entry.found_existing) {
                            var prof: ?[]const u8 = cr.profile_path;
                            if (prof == null) {
                                if (catalog.people.get(cr.person_id)) |p| prof = p.profile_path;
                            }
                            entry.value_ptr.* = .{
                                .person_id = cr.person_id,
                                .name = cr.name,
                                .profile_path = prof,
                                .known_for_department = "Directing",
                                .seconds = 0,
                                .plays = 0,
                                .titles_count = 0,
                                .top_role = "Director",
                            };
                        }
                        entry.value_ptr.seconds += stats.seconds;
                        entry.value_ptr.plays += stats.plays;
                        entry.value_ptr.titles_count += 1;
                        if (entry.value_ptr.profile_path == null and cr.profile_path != null) {
                            entry.value_ptr.profile_path = cr.profile_path;
                        }
                    }
                }
            }
        }
    }

    // Process show credits for watched shows
    var s_cr_it = catalog.show_credits.valueIterator();
    while (s_cr_it.next()) |cr| {
        if (show_stats.get(cr.show_id)) |stats| {
            if (stats.seconds > 0 or stats.plays > 0) {
                if (cr.is_cast) {
                    const key = PersonMediaKey{ .person_id = cr.person_id, .media_id = cr.show_id, .is_show = true };
                    if (!actor_seen.contains(key)) {
                        try actor_seen.put(key, {});
                        var entry = try actor_stats.getOrPut(cr.person_id);
                        if (!entry.found_existing) {
                            var prof: ?[]const u8 = cr.profile_path;
                            if (prof == null) {
                                if (catalog.people.get(cr.person_id)) |p| prof = p.profile_path;
                            }
                            entry.value_ptr.* = .{
                                .person_id = cr.person_id,
                                .name = cr.name,
                                .profile_path = prof,
                                .known_for_department = "Acting",
                                .seconds = 0,
                                .plays = 0,
                                .titles_count = 0,
                                .top_role = cr.character,
                            };
                        }
                        entry.value_ptr.seconds += stats.seconds;
                        entry.value_ptr.plays += stats.plays;
                        entry.value_ptr.titles_count += 1;
                        if (entry.value_ptr.profile_path == null and cr.profile_path != null) {
                            entry.value_ptr.profile_path = cr.profile_path;
                        }
                    }
                }

                const is_dir = !cr.is_cast and (std.mem.eql(u8, cr.department, "Directing") or (cr.job != null and (std.mem.indexOf(u8, cr.job.?, "Director") != null or std.mem.indexOf(u8, cr.job.?, "Creator") != null)));
                if (is_dir) {
                    const key = PersonMediaKey{ .person_id = cr.person_id, .media_id = cr.show_id, .is_show = true };
                    if (!director_seen.contains(key)) {
                        try director_seen.put(key, {});
                        var entry = try director_stats.getOrPut(cr.person_id);
                        if (!entry.found_existing) {
                            var prof: ?[]const u8 = cr.profile_path;
                            if (prof == null) {
                                if (catalog.people.get(cr.person_id)) |p| prof = p.profile_path;
                            }
                            entry.value_ptr.* = .{
                                .person_id = cr.person_id,
                                .name = cr.name,
                                .profile_path = prof,
                                .known_for_department = "Directing",
                                .seconds = 0,
                                .plays = 0,
                                .titles_count = 0,
                                .top_role = "Creator / Director",
                            };
                        }
                        entry.value_ptr.seconds += stats.seconds;
                        entry.value_ptr.plays += stats.plays;
                        entry.value_ptr.titles_count += 1;
                        if (entry.value_ptr.profile_path == null and cr.profile_path != null) {
                            entry.value_ptr.profile_path = cr.profile_path;
                        }
                    }
                }
            }
        }
    }

    var actors_list = std.ArrayList(WatchedPersonItem).empty;
    var act_it = actor_stats.valueIterator();
    while (act_it.next()) |v| {
        try actors_list.append(aa, .{
            .person_id = v.person_id,
            .name = try aa.dupe(u8, v.name),
            .profile_path = if (v.profile_path) |p| try aa.dupe(u8, p) else null,
            .known_for_department = try aa.dupe(u8, v.known_for_department orelse "Acting"),
            .seconds_watched = v.seconds,
            .play_count = v.plays,
            .titles_count = v.titles_count,
            .top_role = if (v.top_role) |r| try aa.dupe(u8, r) else null,
        });
    }
    std.mem.sort(WatchedPersonItem, actors_list.items, sort_order, personLessThan);
    const actor_count = @min(limit, actors_list.items.len);
    const top_actors = actors_list.items[0..actor_count];

    var directors_list = std.ArrayList(WatchedPersonItem).empty;
    var dir_it = director_stats.valueIterator();
    while (dir_it.next()) |v| {
        try directors_list.append(aa, .{
            .person_id = v.person_id,
            .name = try aa.dupe(u8, v.name),
            .profile_path = if (v.profile_path) |p| try aa.dupe(u8, p) else null,
            .known_for_department = try aa.dupe(u8, v.known_for_department orelse "Directing"),
            .seconds_watched = v.seconds,
            .play_count = v.plays,
            .titles_count = v.titles_count,
            .top_role = if (v.top_role) |r| try aa.dupe(u8, r) else null,
        });
    }
    std.mem.sort(WatchedPersonItem, directors_list.items, sort_order, personLessThan);
    const director_count = @min(limit, directors_list.items.len);
    const top_directors = directors_list.items[0..director_count];

    // =========================================================================
    // 4. Compute Library Intelligence & Trivia
    // =========================================================================
    const TitleKey = struct {
        id: i64,
        is_show: bool,
    };
    const TitleInfo = struct {
        id: i64,
        is_show: bool,
        name: []const u8,
    };
    const ActorTitles = struct {
        name: []const u8,
        profile_path: ?[]const u8,
        titles: std.AutoHashMap(TitleKey, []const u8),
    };

    var actor_title_map = std.AutoHashMap(i64, ActorTitles).init(aa);

    var all_m_cr = catalog.movie_credits.valueIterator();
    while (all_m_cr.next()) |cr| {
        if (!cr.is_cast) continue;
        if (catalog.movies.get(cr.movie_id)) |m| {
            if (m.is_present) {
                const title_name = if (m.title) |t| t else m.clean_name;
                var entry = try actor_title_map.getOrPut(cr.person_id);
                if (!entry.found_existing) {
                    var prof: ?[]const u8 = cr.profile_path;
                    if (prof == null) {
                        if (catalog.people.get(cr.person_id)) |p| prof = p.profile_path;
                    }
                    entry.value_ptr.* = .{
                        .name = cr.name,
                        .profile_path = prof,
                        .titles = std.AutoHashMap(TitleKey, []const u8).init(aa),
                    };
                }
                try entry.value_ptr.titles.put(.{ .id = cr.movie_id, .is_show = false }, title_name);
            }
        }
    }

    var all_s_cr = catalog.show_credits.valueIterator();
    while (all_s_cr.next()) |cr| {
        if (!cr.is_cast) continue;
        if (catalog.shows.get(cr.show_id)) |s| {
            if (s.is_present) {
                var entry = try actor_title_map.getOrPut(cr.person_id);
                if (!entry.found_existing) {
                    var prof: ?[]const u8 = cr.profile_path;
                    if (prof == null) {
                        if (catalog.people.get(cr.person_id)) |p| prof = p.profile_path;
                    }
                    entry.value_ptr.* = .{
                        .name = cr.name,
                        .profile_path = prof,
                        .titles = std.AutoHashMap(TitleKey, []const u8).init(aa),
                    };
                }
                try entry.value_ptr.titles.put(.{ .id = cr.show_id, .is_show = true }, s.title);
            }
        }
    }

    // 4.1 Ubiquitous Actor
    var ubiquitous: ?UbiquitousActor = null;
    var max_title_count: usize = 0;
    var atm_tracker_it = actor_title_map.iterator();
    while (atm_tracker_it.next()) |entry| {
        const count = entry.value_ptr.titles.count();
        if (count > max_title_count) {
            max_title_count = count;
            var samples = std.ArrayList([]const u8).empty;
            var t_it = entry.value_ptr.titles.valueIterator();
            while (t_it.next()) |t_name| {
                if (samples.items.len >= 3) break;
                try samples.append(aa, try aa.dupe(u8, t_name.*));
            }
            ubiquitous = .{
                .person_id = entry.key_ptr.*,
                .name = try aa.dupe(u8, entry.value_ptr.name),
                .profile_path = if (entry.value_ptr.profile_path) |p| try aa.dupe(u8, p) else null,
                .title_count = count,
                .sample_titles = samples.items,
            };
        }
    }
    if (max_title_count < 2) ubiquitous = null;

    // 4.2 Title Crossover (Largest Cast Overlap)
    const TitlePairKey = struct {
        t1: TitleKey,
        t2: TitleKey,
    };
    const TitlePairValue = struct {
        t1_name: []const u8,
        t2_name: []const u8,
        actors: std.ArrayList([]const u8),
    };
    var title_pair_map = std.AutoHashMap(TitlePairKey, TitlePairValue).init(aa);

    var atm_it = actor_title_map.iterator();
    while (atm_it.next()) |entry| {
        if (entry.value_ptr.titles.count() < 2) continue;
        const actor_name = entry.value_ptr.name;

        var t_keys = std.ArrayList(TitleInfo).empty;
        var t_it = entry.value_ptr.titles.iterator();
        while (t_it.next()) |t_entry| {
            try t_keys.append(aa, .{
                .id = t_entry.key_ptr.id,
                .is_show = t_entry.key_ptr.is_show,
                .name = t_entry.value_ptr.*,
            });
        }

        var i: usize = 0;
        while (i < t_keys.items.len) : (i += 1) {
            var j: usize = i + 1;
            while (j < t_keys.items.len) : (j += 1) {
                const k1 = t_keys.items[i];
                const k2 = t_keys.items[j];

                const is_less = if (k1.is_show != k2.is_show) !k1.is_show else k1.id < k2.id;
                const pair_key = if (is_less)
                    TitlePairKey{ .t1 = .{ .id = k1.id, .is_show = k1.is_show }, .t2 = .{ .id = k2.id, .is_show = k2.is_show } }
                else
                    TitlePairKey{ .t1 = .{ .id = k2.id, .is_show = k2.is_show }, .t2 = .{ .id = k1.id, .is_show = k1.is_show } };

                const pair_entry = try title_pair_map.getOrPut(pair_key);
                if (!pair_entry.found_existing) {
                    pair_entry.value_ptr.* = .{
                        .t1_name = if (is_less) k1.name else k2.name,
                        .t2_name = if (is_less) k2.name else k1.name,
                        .actors = std.ArrayList([]const u8).empty,
                    };
                }
                try pair_entry.value_ptr.actors.append(aa, actor_name);
            }
        }
    }

    var crossover: ?TitleCrossover = null;
    var max_crossover_count: usize = 0;
    var tp_it = title_pair_map.iterator();
    while (tp_it.next()) |entry| {
        const count = entry.value_ptr.actors.items.len;
        if (count > max_crossover_count) {
            max_crossover_count = count;
            const top_act_count = @min(4, count);
            var sample_actors = std.ArrayList([]const u8).empty;
            for (entry.value_ptr.actors.items[0..top_act_count]) |act| {
                try sample_actors.append(aa, try aa.dupe(u8, act));
            }
            crossover = .{
                .title_a_id = entry.key_ptr.t1.id,
                .title_a_name = try aa.dupe(u8, entry.value_ptr.t1_name),
                .title_a_is_show = entry.key_ptr.t1.is_show,
                .title_b_id = entry.key_ptr.t2.id,
                .title_b_name = try aa.dupe(u8, entry.value_ptr.t2_name),
                .title_b_is_show = entry.key_ptr.t2.is_show,
                .shared_actor_count = count,
                .shared_actors = sample_actors.items,
            };
        }
    }
    if (max_crossover_count < 2) crossover = null;

    // 4.3 Dynamic Duo (Collaborator Pairs)
    const PairKey = struct {
        p1: i64,
        p2: i64,
    };
    const PairRecord = struct {
        p1_name: []const u8,
        p1_role: []const u8,
        p2_name: []const u8,
        p2_role: []const u8,
        titles: std.ArrayList([]const u8),
    };

    var dir_actor_pairs = std.AutoHashMap(PairKey, PairRecord).init(aa);
    var actor_actor_pairs = std.AutoHashMap(PairKey, PairRecord).init(aa);

    const PersonBrief = struct {
        id: i64,
        name: []const u8,
    };

    var movie_it = catalog.movies.valueIterator();
    while (movie_it.next()) |m| {
        if (!m.is_present) continue;
        const title_name = if (m.title) |t| t else m.clean_name;

        var dirs = std.ArrayList(PersonBrief).empty;
        var acts = std.ArrayList(PersonBrief).empty;

        var m_cr_iter = catalog.movie_credits.valueIterator();
        while (m_cr_iter.next()) |cr| {
            if (cr.movie_id != m.id) continue;
            if (cr.is_cast and cr.order < 12) {
                try acts.append(aa, .{ .id = cr.person_id, .name = cr.name });
            } else if (!cr.is_cast and (std.mem.eql(u8, cr.department, "Directing") or (cr.job != null and std.mem.indexOf(u8, cr.job.?, "Director") != null))) {
                try dirs.append(aa, .{ .id = cr.person_id, .name = cr.name });
            }
        }

        for (dirs.items) |d| {
            for (acts.items) |a| {
                if (d.id == a.id) continue;
                const p_key = PairKey{ .p1 = d.id, .p2 = a.id };
                var entry = try dir_actor_pairs.getOrPut(p_key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .p1_name = d.name,
                        .p1_role = "Director",
                        .p2_name = a.name,
                        .p2_role = "Actor",
                        .titles = std.ArrayList([]const u8).empty,
                    };
                }
                try entry.value_ptr.titles.append(aa, title_name);
            }
        }

        for (acts.items, 0..) |a1, idx| {
            for (acts.items[idx + 1 ..]) |a2| {
                const min_id = @min(a1.id, a2.id);
                const max_id = @max(a1.id, a2.id);
                const p_key = PairKey{ .p1 = min_id, .p2 = max_id };
                var entry = try actor_actor_pairs.getOrPut(p_key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .p1_name = if (min_id == a1.id) a1.name else a2.name,
                        .p1_role = "Actor",
                        .p2_name = if (min_id == a1.id) a2.name else a1.name,
                        .p2_role = "Actor",
                        .titles = std.ArrayList([]const u8).empty,
                    };
                }
                try entry.value_ptr.titles.append(aa, title_name);
            }
        }
    }

    var show_it = catalog.shows.valueIterator();
    while (show_it.next()) |s| {
        if (!s.is_present) continue;
        const title_name = s.title;

        var dirs = std.ArrayList(PersonBrief).empty;
        var acts = std.ArrayList(PersonBrief).empty;

        var s_cr_iter = catalog.show_credits.valueIterator();
        while (s_cr_iter.next()) |cr| {
            if (cr.show_id != s.id) continue;
            if (cr.is_cast and cr.order < 12) {
                try acts.append(aa, .{ .id = cr.person_id, .name = cr.name });
            } else if (!cr.is_cast and (std.mem.eql(u8, cr.department, "Directing") or (cr.job != null and (std.mem.indexOf(u8, cr.job.?, "Director") != null or std.mem.indexOf(u8, cr.job.?, "Creator") != null)))) {
                try dirs.append(aa, .{ .id = cr.person_id, .name = cr.name });
            }
        }

        for (dirs.items) |d| {
            for (acts.items) |a| {
                if (d.id == a.id) continue;
                const p_key = PairKey{ .p1 = d.id, .p2 = a.id };
                var entry = try dir_actor_pairs.getOrPut(p_key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .p1_name = d.name,
                        .p1_role = "Director",
                        .p2_name = a.name,
                        .p2_role = "Actor",
                        .titles = std.ArrayList([]const u8).empty,
                    };
                }
                try entry.value_ptr.titles.append(aa, title_name);
            }
        }

        for (acts.items, 0..) |a1, idx| {
            for (acts.items[idx + 1 ..]) |a2| {
                const min_id = @min(a1.id, a2.id);
                const max_id = @max(a1.id, a2.id);
                const p_key = PairKey{ .p1 = min_id, .p2 = max_id };
                var entry = try actor_actor_pairs.getOrPut(p_key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{
                        .p1_name = if (min_id == a1.id) a1.name else a2.name,
                        .p1_role = "Actor",
                        .p2_name = if (min_id == a1.id) a2.name else a1.name,
                        .p2_role = "Actor",
                        .titles = std.ArrayList([]const u8).empty,
                    };
                }
                try entry.value_ptr.titles.append(aa, title_name);
            }
        }
    }

    var collaborators: ?CollaboratorPair = null;
    var best_dir_pair: ?PairRecord = null;
    var best_dir_count: usize = 0;
    var best_dir_key: ?PairKey = null;

    var dap_it = dir_actor_pairs.iterator();
    while (dap_it.next()) |entry| {
        const count = entry.value_ptr.titles.items.len;
        if (count > best_dir_count) {
            best_dir_count = count;
            best_dir_pair = entry.value_ptr.*;
            best_dir_key = entry.key_ptr.*;
        }
    }

    var best_act_pair: ?PairRecord = null;
    var best_act_count: usize = 0;
    var best_act_key: ?PairKey = null;

    var aap_it = actor_actor_pairs.iterator();
    while (aap_it.next()) |entry| {
        const count = entry.value_ptr.titles.items.len;
        if (count > best_act_count) {
            best_act_count = count;
            best_act_pair = entry.value_ptr.*;
            best_act_key = entry.key_ptr.*;
        }
    }

    if (best_dir_count >= 3) {
        const bp = best_dir_pair.?;
        const bk = best_dir_key.?;
        const sample_len = @min(3, bp.titles.items.len);
        var sample_titles = std.ArrayList([]const u8).empty;
        for (bp.titles.items[0..sample_len]) |t| {
            try sample_titles.append(aa, try aa.dupe(u8, t));
        }
        collaborators = .{
            .person_a_id = bk.p1,
            .person_a_name = try aa.dupe(u8, bp.p1_name),
            .person_a_role = try aa.dupe(u8, bp.p1_role),
            .person_b_id = bk.p2,
            .person_b_name = try aa.dupe(u8, bp.p2_name),
            .person_b_role = try aa.dupe(u8, bp.p2_role),
            .shared_title_count = bp.titles.items.len,
            .shared_titles = sample_titles.items,
        };
    } else if (best_dir_count >= 2 or best_act_count >= 2) {
        if (best_dir_count >= best_act_count) {
            const bp = best_dir_pair.?;
            const bk = best_dir_key.?;
            const sample_len = @min(3, bp.titles.items.len);
            var sample_titles = std.ArrayList([]const u8).empty;
            for (bp.titles.items[0..sample_len]) |t| {
                try sample_titles.append(aa, try aa.dupe(u8, t));
            }
            collaborators = .{
                .person_a_id = bk.p1,
                .person_a_name = try aa.dupe(u8, bp.p1_name),
                .person_a_role = try aa.dupe(u8, bp.p1_role),
                .person_b_id = bk.p2,
                .person_b_name = try aa.dupe(u8, bp.p2_name),
                .person_b_role = try aa.dupe(u8, bp.p2_role),
                .shared_title_count = bp.titles.items.len,
                .shared_titles = sample_titles.items,
            };
        } else {
            const bp = best_act_pair.?;
            const bk = best_act_key.?;
            const sample_len = @min(3, bp.titles.items.len);
            var sample_titles = std.ArrayList([]const u8).empty;
            for (bp.titles.items[0..sample_len]) |t| {
                try sample_titles.append(aa, try aa.dupe(u8, t));
            }
            collaborators = .{
                .person_a_id = bk.p1,
                .person_a_name = try aa.dupe(u8, bp.p1_name),
                .person_a_role = try aa.dupe(u8, bp.p1_role),
                .person_b_id = bk.p2,
                .person_b_name = try aa.dupe(u8, bp.p2_name),
                .person_b_role = try aa.dupe(u8, bp.p2_role),
                .shared_title_count = bp.titles.items.len,
                .shared_titles = sample_titles.items,
            };
        }
    }

    // 4.4 Decade Time Machine (Era Breakdown)
    var eras = [_]EraPoint{
        .{ .decade = 1960, .label = "Classic", .seconds_watched = 0, .title_count = 0, .percent = 0 },
        .{ .decade = 1970, .label = "1970s", .seconds_watched = 0, .title_count = 0, .percent = 0 },
        .{ .decade = 1980, .label = "1980s", .seconds_watched = 0, .title_count = 0, .percent = 0 },
        .{ .decade = 1990, .label = "1990s", .seconds_watched = 0, .title_count = 0, .percent = 0 },
        .{ .decade = 2000, .label = "2000s", .seconds_watched = 0, .title_count = 0, .percent = 0 },
        .{ .decade = 2010, .label = "2010s", .seconds_watched = 0, .title_count = 0, .percent = 0 },
        .{ .decade = 2020, .label = "2020s", .seconds_watched = 0, .title_count = 0, .percent = 0 },
    };

    var total_era_seconds: u64 = 0;
    var total_era_titles: usize = 0;

    var m_st_it = movie_stats.iterator();
    while (m_st_it.next()) |entry| {
        if (entry.value_ptr.seconds == 0 and entry.value_ptr.plays == 0) continue;
        if (catalog.movies.get(entry.key_ptr.*)) |m| {
            const yr_opt = parseYear(m.release_date) orelse findYearInString(m.clean_name);
            if (yr_opt) |yr| {
                const dec = yearToDecade(yr);
                for (&eras) |*era| {
                    if (era.decade == dec) {
                        era.seconds_watched += entry.value_ptr.seconds;
                        era.title_count += 1;
                        total_era_seconds += entry.value_ptr.seconds;
                        total_era_titles += 1;
                        break;
                    }
                }
            }
        }
    }

    var s_st_it = show_stats.iterator();
    while (s_st_it.next()) |entry| {
        if (entry.value_ptr.seconds == 0 and entry.value_ptr.plays == 0) continue;
        if (catalog.shows.get(entry.key_ptr.*)) |s| {
            const yr_opt = findYearInString(s.title) orelse findYearInString(s.path);
            if (yr_opt) |yr| {
                const dec = yearToDecade(yr);
                for (&eras) |*era| {
                    if (era.decade == dec) {
                        era.seconds_watched += entry.value_ptr.seconds;
                        era.title_count += 1;
                        total_era_seconds += entry.value_ptr.seconds;
                        total_era_titles += 1;
                        break;
                    }
                }
            }
        }
    }

    if (total_era_seconds == 0) {
        var all_m = catalog.movies.valueIterator();
        while (all_m.next()) |m| {
            if (!m.is_present) continue;
            const yr_opt = parseYear(m.release_date) orelse findYearInString(m.clean_name);
            if (yr_opt) |yr| {
                const dec = yearToDecade(yr);
                for (&eras) |*era| {
                    if (era.decade == dec) {
                        era.title_count += 1;
                        total_era_titles += 1;
                        break;
                    }
                }
            }
        }
        var all_s = catalog.shows.valueIterator();
        while (all_s.next()) |s| {
            if (!s.is_present) continue;
            const yr_opt = findYearInString(s.title) orelse findYearInString(s.path);
            if (yr_opt) |yr| {
                const dec = yearToDecade(yr);
                for (&eras) |*era| {
                    if (era.decade == dec) {
                        era.title_count += 1;
                        total_era_titles += 1;
                        break;
                    }
                }
            }
        }

        if (total_era_titles > 0) {
            for (&eras) |*era| {
                era.percent = @intCast((era.title_count * 100) / total_era_titles);
            }
        }
    } else {
        for (&eras) |*era| {
            era.percent = @intCast((era.seconds_watched * 100) / total_era_seconds);
        }
    }

    var era_slice = try aa.alloc(EraPoint, eras.len);
    for (eras, 0..) |e, idx| {
        era_slice[idx] = .{
            .decade = e.decade,
            .label = try aa.dupe(u8, e.label),
            .seconds_watched = e.seconds_watched,
            .title_count = e.title_count,
            .percent = e.percent,
        };
    }

    const trivia = AnalyticsTrivia{
        .ubiquitous_actor = ubiquitous,
        .collaborators = collaborators,
        .crossover = crossover,
        .eras = era_slice,
    };

    return .{
        .arena = arena,
        .range = range,
        .overview = overview,
        .daily_trend = daily_list.items,
        .hourly_distribution = hourly_distribution,
        .top_movies = top_movies,
        .top_shows = top_shows,
        .top_actors = top_actors,
        .top_directors = top_directors,
        .trivia = trivia,
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

test "analytics: star power and library trivia computation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_analytics_cat3.json", "tmp/test_analytics_cat3.wal", "tmp/test_analytics_cat3_persons");
    defer cat.deinit();

    // 1. Seed people
    try cat.addOrUpdatePerson(.{ .id = 1, .name = "Cillian Murphy", .known_for_department = "Acting" });
    try cat.addOrUpdatePerson(.{ .id = 2, .name = "Christopher Nolan", .known_for_department = "Directing" });
    try cat.addOrUpdatePerson(.{ .id = 3, .name = "Tom Hardy", .known_for_department = "Acting" });

    // 2. Seed movies & show
    const m1_id = try cat.addOrUpdateMovie(.{
        .id = 1,
        .library_id = 1,
        .file_path = "/path/m1.mkv",
        .clean_name = "Inception",
        .title = "Inception",
        .release_date = "2010-07-16",
    });
    const m2_id = try cat.addOrUpdateMovie(.{
        .id = 2,
        .library_id = 1,
        .file_path = "/path/m2.mkv",
        .clean_name = "Dunkirk",
        .title = "Dunkirk",
        .release_date = "2017-07-21",
    });
    const s1_id = try cat.addOrUpdateShow(.{
        .id = 10,
        .library_id = 2,
        .path = "/path/Peaky Blinders (2013)",
        .title = "Peaky Blinders (2013)",
    });
    const ep1_id = try cat.addOrUpdateEpisode(.{
        .id = 101,
        .show_id = s1_id,
        .file_path = "/path/ep1.mkv",
        .season = 1,
        .episode = 1,
    });

    // 3. Seed credits
    // Inception: Nolan directs, Cillian acts, Tom Hardy acts
    _ = try cat.addMovieCredit(.{ .id = 1, .movie_id = m1_id, .person_id = 2, .name = "Christopher Nolan", .department = "Directing", .job = "Director", .is_cast = false });
    _ = try cat.addMovieCredit(.{ .id = 2, .movie_id = m1_id, .person_id = 1, .name = "Cillian Murphy", .character = "Robert Fischer", .is_cast = true, .order = 1 });
    _ = try cat.addMovieCredit(.{ .id = 3, .movie_id = m1_id, .person_id = 3, .name = "Tom Hardy", .character = "Eames", .is_cast = true, .order = 2 });

    // Dunkirk: Nolan directs, Cillian acts, Tom Hardy acts
    _ = try cat.addMovieCredit(.{ .id = 4, .movie_id = m2_id, .person_id = 2, .name = "Christopher Nolan", .department = "Directing", .job = "Director", .is_cast = false });
    _ = try cat.addMovieCredit(.{ .id = 5, .movie_id = m2_id, .person_id = 1, .name = "Cillian Murphy", .character = "Shivering Soldier", .is_cast = true, .order = 1 });
    _ = try cat.addMovieCredit(.{ .id = 6, .movie_id = m2_id, .person_id = 3, .name = "Tom Hardy", .character = "Farrier", .is_cast = true, .order = 2 });

    // Peaky Blinders: Cillian Murphy stars, Tom Hardy guest stars
    _ = try cat.addShowCredit(.{ .id = 7, .show_id = s1_id, .person_id = 1, .name = "Cillian Murphy", .character = "Thomas Shelby", .is_cast = true, .order = 0 });
    _ = try cat.addShowCredit(.{ .id = 8, .show_id = s1_id, .person_id = 3, .name = "Tom Hardy", .character = "Alfie Solomons", .is_cast = true, .order = 1 });

    // 4. Seed playback logs: Inception (50s), Dunkirk (30s), Peaky Blinders (40s)
    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_analytics_logs3.json", "tmp/test_analytics_logs3.wal");
    defer logs.deinit();

    try logs.logPlaybackEvent("alice", m1_id, "start", 0.0);
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try logs.logPlaybackEvent("alice", m1_id, "progress", @floatFromInt((i + 1) * 10));
    }
    try logs.logPlaybackEvent("alice", m2_id, "start", 0.0);
    i = 0;
    while (i < 3) : (i += 1) {
        try logs.logPlaybackEvent("alice", m2_id, "progress", @floatFromInt((i + 1) * 10));
    }
    try logs.logEpisodePlaybackEvent("alice", ep1_id, "start", 0.0);
    i = 0;
    while (i < 4) : (i += 1) {
        try logs.logEpisodePlaybackEvent("alice", ep1_id, "progress", @floatFromInt((i + 1) * 10));
    }

    var report = try computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    // 5. Verify Star Power:
    // Cillian Murphy watched in Inception (50s) + Dunkirk (30s) + Peaky (40s) = 120s
    // Christopher Nolan watched in Inception (50s) + Dunkirk (30s) = 80s
    try std.testing.expect(report.top_actors.len >= 2);
    try std.testing.expectEqualStrings("Cillian Murphy", report.top_actors[0].name);
    try std.testing.expectEqual(@as(u64, 120), report.top_actors[0].seconds_watched);
    try std.testing.expectEqual(@as(usize, 3), report.top_actors[0].titles_count);

    try std.testing.expect(report.top_directors.len >= 1);
    try std.testing.expectEqualStrings("Christopher Nolan", report.top_directors[0].name);
    try std.testing.expectEqual(@as(u64, 80), report.top_directors[0].seconds_watched);
    try std.testing.expectEqual(@as(usize, 2), report.top_directors[0].titles_count);

    // 6. Verify Trivia:
    // Ubiquitous actor: Cillian Murphy or Tom Hardy appears in 3 titles (Inception, Dunkirk, Peaky)
    try std.testing.expect(report.trivia.ubiquitous_actor != null);
    try std.testing.expect(report.trivia.ubiquitous_actor.?.title_count >= 3);

    // Title crossover: Inception & Dunkirk share 2 actors (Cillian Murphy, Tom Hardy)
    try std.testing.expect(report.trivia.crossover != null);
    try std.testing.expectEqual(@as(usize, 2), report.trivia.crossover.?.shared_actor_count);

    // Dynamic duo: collaborators found with shared_title_count >= 2
    try std.testing.expect(report.trivia.collaborators != null);
    try std.testing.expect(report.trivia.collaborators.?.shared_title_count >= 2);

    // Eras: 2010s has 100% of watch time (Inception 2010, Dunkirk 2017, Peaky 2013)
    try std.testing.expectEqual(@as(usize, 7), report.trivia.eras.len);
    for (report.trivia.eras) |era| {
        if (era.decade == 2010) {
            try std.testing.expectEqual(@as(u8, 100), era.percent);
        } else {
            try std.testing.expectEqual(@as(u8, 0), era.percent);
        }
    }
}
