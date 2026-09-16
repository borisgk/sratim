const std = @import("std");
const db_mod = @import("../../db/db.zig");
const engine = @import("../../storage/engine.zig");
const logs_engine = @import("../../storage/logs_engine.zig");
const analytics_mod = @import("../../db/analytics.zig");
const template_engine = @import("../../core/template.zig");
const global_css: []const u8 = @embedFile("../style.css");

fn escapeJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
}

fn appendFormatted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(formatted);
    try out.appendSlice(allocator, formatted);
}

pub fn formatWatchTime(allocator: std.mem.Allocator, seconds: u64) ![]u8 {
    if (seconds >= 3600) {
        const hrs = seconds / 3600;
        const mins = (seconds % 3600) / 60;
        return try std.fmt.allocPrint(allocator, "{d}h {d:0>2}m", .{ hrs, mins });
    } else if (seconds >= 60) {
        const mins = seconds / 60;
        const secs = seconds % 60;
        return try std.fmt.allocPrint(allocator, "{d}m {d:0>2}s", .{ mins, secs });
    } else {
        return try std.fmt.allocPrint(allocator, "{d}s", .{seconds});
    }
}

pub fn serializeReportToJson(allocator: std.mem.Allocator, report: *const analytics_mod.AnalyticsReport) ![]u8 {
    var json = std.ArrayList(u8).empty;
    errdefer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"range\":\"");
    try json.appendSlice(allocator, report.range.asString());
    try json.appendSlice(allocator, "\",\"overview\":{");

    try appendFormatted(&json, allocator, "\"total_watch_seconds\":{d},\"total_plays\":{d},\"active_viewers\":{d},\"peak_hour\":{d},\"total_movies_watched\":{d},\"total_episodes_watched\":{d}", .{
        report.overview.total_watch_seconds,
        report.overview.total_plays,
        report.overview.active_viewers,
        report.overview.peak_hour,
        report.overview.total_movies_watched,
        report.overview.total_episodes_watched,
    });
    try json.appendSlice(allocator, "},\"daily_trend\":[");

    for (report.daily_trend, 0..) |p, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{{\"day_epoch\":{d},\"date\":\"{s}\",\"seconds\":{d},\"plays\":{d}}}", .{
            p.day_epoch,
            p.date_str,
            p.seconds_watched,
            p.play_count,
        });
    }
    try json.appendSlice(allocator, "],\"hourly_distribution\":[");

    for (report.hourly_distribution, 0..) |val, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{d}", .{val});
    }
    try json.appendSlice(allocator, "],\"top_movies\":[");

    for (report.top_movies, 0..) |m, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{{\"movie_id\":{d},\"title\":\"", .{m.movie_id});
        try escapeJsonString(&json, allocator, m.title);
        try json.appendSlice(allocator, "\"");

        if (m.poster_path) |p| {
            try json.appendSlice(allocator, ",\"poster_path\":\"");
            try escapeJsonString(&json, allocator, p);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"poster_path\":null");
        }

        if (m.release_date) |r| {
            try json.appendSlice(allocator, ",\"release_date\":\"");
            try escapeJsonString(&json, allocator, r);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"release_date\":null");
        }

        try appendFormatted(&json, allocator, ",\"seconds\":{d},\"plays\":{d}}}", .{ m.seconds_watched, m.play_count });
    }
    try json.appendSlice(allocator, "],\"top_shows\":[");

    for (report.top_shows, 0..) |s, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{{\"show_id\":{d},\"title\":\"", .{s.show_id});
        try escapeJsonString(&json, allocator, s.title);
        try json.appendSlice(allocator, "\"");

        if (s.poster_path) |p| {
            try json.appendSlice(allocator, ",\"poster_path\":\"");
            try escapeJsonString(&json, allocator, p);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"poster_path\":null");
        }

        try appendFormatted(&json, allocator, ",\"seconds\":{d},\"episodes_played\":{d},\"plays\":{d}}}", .{ s.seconds_watched, s.episodes_played, s.play_count });
    }
    try json.appendSlice(allocator, "],\"top_actors\":[");
    for (report.top_actors, 0..) |act, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{{\"person_id\":{d},\"name\":\"", .{act.person_id});
        try escapeJsonString(&json, allocator, act.name);
        try json.appendSlice(allocator, "\"");

        if (act.profile_path) |p| {
            try json.appendSlice(allocator, ",\"profile_path\":\"");
            try escapeJsonString(&json, allocator, p);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"profile_path\":null");
        }

        if (act.known_for_department) |d| {
            try json.appendSlice(allocator, ",\"department\":\"");
            try escapeJsonString(&json, allocator, d);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"department\":null");
        }

        if (act.top_role) |r| {
            try json.appendSlice(allocator, ",\"top_role\":\"");
            try escapeJsonString(&json, allocator, r);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"top_role\":null");
        }

        try appendFormatted(&json, allocator, ",\"seconds\":{d},\"plays\":{d},\"titles_count\":{d}}}", .{ act.seconds_watched, act.play_count, act.titles_count });
    }

    try json.appendSlice(allocator, "],\"top_directors\":[");
    for (report.top_directors, 0..) |dir, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{{\"person_id\":{d},\"name\":\"", .{dir.person_id});
        try escapeJsonString(&json, allocator, dir.name);
        try json.appendSlice(allocator, "\"");

        if (dir.profile_path) |p| {
            try json.appendSlice(allocator, ",\"profile_path\":\"");
            try escapeJsonString(&json, allocator, p);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"profile_path\":null");
        }

        if (dir.top_role) |r| {
            try json.appendSlice(allocator, ",\"top_role\":\"");
            try escapeJsonString(&json, allocator, r);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"top_role\":null");
        }

        try appendFormatted(&json, allocator, ",\"seconds\":{d},\"plays\":{d},\"titles_count\":{d}}}", .{ dir.seconds_watched, dir.play_count, dir.titles_count });
    }

    try json.appendSlice(allocator, "],\"trivia\":{");

    // 1. Ubiquitous actor
    if (report.trivia.ubiquitous_actor) |u| {
        try appendFormatted(&json, allocator, "\"ubiquitous_actor\":{{\"person_id\":{d},\"name\":\"", .{u.person_id});
        try escapeJsonString(&json, allocator, u.name);
        try json.appendSlice(allocator, "\"");

        if (u.profile_path) |p| {
            try json.appendSlice(allocator, ",\"profile_path\":\"");
            try escapeJsonString(&json, allocator, p);
            try json.appendSlice(allocator, "\"");
        } else {
            try json.appendSlice(allocator, ",\"profile_path\":null");
        }

        try appendFormatted(&json, allocator, ",\"title_count\":{d},\"sample_titles\":[", .{u.title_count});
        for (u.sample_titles, 0..) |t, idx| {
            if (idx > 0) try json.appendSlice(allocator, ",");
            try json.appendSlice(allocator, "\"");
            try escapeJsonString(&json, allocator, t);
            try json.appendSlice(allocator, "\"");
        }
        try json.appendSlice(allocator, "]}");
    } else {
        try json.appendSlice(allocator, "\"ubiquitous_actor\":null");
    }

    // 2. Collaborators
    if (report.trivia.collaborators) |c| {
        try appendFormatted(&json, allocator, ",\"collaborators\":{{\"person_a_id\":{d},\"person_a_name\":\"", .{c.person_a_id});
        try escapeJsonString(&json, allocator, c.person_a_name);
        try json.appendSlice(allocator, "\",\"person_a_role\":\"");
        try escapeJsonString(&json, allocator, c.person_a_role);
        try appendFormatted(&json, allocator, "\",\"person_b_id\":{d},\"person_b_name\":\"", .{c.person_b_id});
        try escapeJsonString(&json, allocator, c.person_b_name);
        try json.appendSlice(allocator, "\",\"person_b_role\":\"");
        try escapeJsonString(&json, allocator, c.person_b_role);
        try appendFormatted(&json, allocator, "\",\"shared_title_count\":{d},\"shared_titles\":[", .{c.shared_title_count});
        for (c.shared_titles, 0..) |t, idx| {
            if (idx > 0) try json.appendSlice(allocator, ",");
            try json.appendSlice(allocator, "\"");
            try escapeJsonString(&json, allocator, t);
            try json.appendSlice(allocator, "\"");
        }
        try json.appendSlice(allocator, "]}");
    } else {
        try json.appendSlice(allocator, ",\"collaborators\":null");
    }

    // 3. Title Crossover
    if (report.trivia.crossover) |x| {
        try appendFormatted(&json, allocator, ",\"crossover\":{{\"title_a_id\":{d},\"title_a_name\":\"", .{x.title_a_id});
        try escapeJsonString(&json, allocator, x.title_a_name);
        try json.appendSlice(allocator, if (x.title_a_is_show) "\",\"title_a_is_show\":true" else "\",\"title_a_is_show\":false");

        try appendFormatted(&json, allocator, ",\"title_b_id\":{d},\"title_b_name\":\"", .{x.title_b_id});
        try escapeJsonString(&json, allocator, x.title_b_name);
        try json.appendSlice(allocator, if (x.title_b_is_show) "\",\"title_b_is_show\":true" else "\",\"title_b_is_show\":false");

        try appendFormatted(&json, allocator, ",\"shared_actor_count\":{d},\"shared_actors\":[", .{x.shared_actor_count});
        for (x.shared_actors, 0..) |a, idx| {
            if (idx > 0) try json.appendSlice(allocator, ",");
            try json.appendSlice(allocator, "\"");
            try escapeJsonString(&json, allocator, a);
            try json.appendSlice(allocator, "\"");
        }
        try json.appendSlice(allocator, "]}");
    } else {
        try json.appendSlice(allocator, ",\"crossover\":null");
    }

    // 4. Eras
    try json.appendSlice(allocator, ",\"eras\":[");
    for (report.trivia.eras, 0..) |e, idx| {
        if (idx > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{{\"decade\":{d},\"label\":\"", .{e.decade});
        try escapeJsonString(&json, allocator, e.label);
        try appendFormatted(&json, allocator, "\",\"seconds\":{d},\"title_count\":{d},\"percent\":{d}}}", .{ e.seconds_watched, e.title_count, e.percent });
    }
    try json.appendSlice(allocator, "]}");

    try json.appendSlice(allocator, ",\"user_activity\":[");

    for (report.user_activity, 0..) |u, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try appendFormatted(&json, allocator, "{{\"username\":\"", .{});
        try escapeJsonString(&json, allocator, u.username);
        try json.appendSlice(allocator, "\"");

        try appendFormatted(&json, allocator, ",\"seconds\":{d},\"plays\":{d},\"last_active\":{d}}}", .{ u.seconds_watched, u.play_count, u.last_active });
    }
    try json.appendSlice(allocator, "]}");

    return try json.toOwnedSlice(allocator);
}

/// Serves the complete HTML Media Analytics Dashboard at GET /admin/analytics
pub fn serveAnalyticsPage(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const logs = logs_database.logs orelse return error.LogsNotConfigured;

    var report = try analytics_mod.computeReport(allocator, cat, logs, .d30, .watch_time, 20);
    defer report.deinit();

    const json_data = try serializeReportToJson(allocator, &report);
    defer allocator.free(json_data);

    const watch_time_str = try formatWatchTime(allocator, report.overview.total_watch_seconds);
    defer allocator.free(watch_time_str);

    const plays_str = try std.fmt.allocPrint(allocator, "{d}", .{report.overview.total_plays});
    defer allocator.free(plays_str);

    const viewers_str = try std.fmt.allocPrint(allocator, "{d}", .{report.overview.active_viewers});
    defer allocator.free(viewers_str);

    const h = report.overview.peak_hour;
    const peak_str = try std.fmt.allocPrint(allocator, "{d:0>2}:00 - {d:0>2}:00", .{ h, (h + 1) % 24 });
    defer allocator.free(peak_str);

    const html = try template_engine.render(allocator, @embedFile("../templates/analytics.html"), .{
        .INLINE_CSS = global_css,
        .ANALYTICS_DATA_JSON = json_data,
        .TOTAL_WATCH_TIME = watch_time_str,
        .TOTAL_PLAYS = plays_str,
        .ACTIVE_VIEWERS = viewers_str,
        .PEAK_HOUR = peak_str,
    });
    defer allocator.free(html);

    request.respond(html, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    }) catch return;
}

/// Handles GET /api/v1/admin/analytics?range=30d&sort=time
pub fn handleApiAnalytics(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const logs = logs_database.logs orelse return error.LogsNotConfigured;

    const target = request.head.target;

    var range: analytics_mod.TimeRange = .d30;
    var sort: analytics_mod.SortOrder = .watch_time;

    if (std.mem.indexOfScalar(u8, target, '?')) |query_start| {
        const query = target[query_start + 1 ..];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "range=")) {
                range = analytics_mod.TimeRange.fromString(param[6..]);
            } else if (std.mem.startsWith(u8, param, "sort=")) {
                sort = analytics_mod.SortOrder.fromString(param[5..]);
            }
        }
    }

    var report = try analytics_mod.computeReport(allocator, cat, logs, range, sort, 25);
    defer report.deinit();

    const json_data = try serializeReportToJson(allocator, &report);
    defer allocator.free(json_data);

    request.respond(json_data, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json; charset=utf-8" },
        },
    }) catch return;
}

test "serializeReportToJson: formats correctly without buffer overflow" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_ser_cat.json", "tmp/test_ser_cat.wal", "tmp/test_ser_cat_persons");
    defer cat.deinit();

    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_ser_logs.json", "tmp/test_ser_logs.wal");
    defer logs.deinit();

    var report = try analytics_mod.computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    report.overview.total_watch_seconds = 999999999;
    report.overview.total_plays = 888888;
    report.overview.active_viewers = 7777;
    report.overview.total_movies_watched = 6666;
    report.overview.total_episodes_watched = 5555;

    const json = try serializeReportToJson(allocator, &report);
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "999999999") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"top_actors\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"top_directors\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trivia\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"eras\":") != null);
}
