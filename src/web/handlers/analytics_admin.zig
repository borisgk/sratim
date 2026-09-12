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
    try json.appendSlice(allocator, "],\"user_activity\":[");

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
}
