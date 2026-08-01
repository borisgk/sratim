const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const logging_mod = @import("../../../db/logging.zig");
const streamer = @import("../../../media/streamer.zig");
const html = @import("../../../core/html.zig");
const utils = @import("../../utils.zig");
const common = @import("common.zig");

/// Handles the HTML Player page endpoint (/player).
pub fn handlePlayer(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    username: []const u8,

    io: std.Io,
) !void {
    const target = request.head.target;
    const movie_id = utils.parseQueryInt(i64, target, "id");
    const episode_id = utils.parseQueryInt(i64, target, "episode_id");

    if (movie_id == null and episode_id == null) {
        try request.respond("Missing movie id or episode id parameter", .{ .status = .bad_request });
        return;
    }

    const media_info_opt = if (movie_id != null)
        metadata_mod.getMovieInfoById(database, allocator, movie_id.?) catch null
    else
        metadata_mod.getEpisodeInfoById(database, allocator, episode_id.?) catch null;

    const resolved = common.resolveMediaPath(database, allocator, media_info_opt) catch |err| {
        if (err == error.PathTraversal) {
            try request.respond("Forbidden", .{ .status = .forbidden });
        } else {
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        }
        return;
    };
    if (resolved == null) {
        try request.respond("Media not found", .{ .status = .not_found });
        return;
    }

    const c_full_path = try allocator.dupeZ(u8, resolved.?.resolved_path);
    defer allocator.free(c_full_path);

    const media_info = streamer.getMediaInfo(allocator, io, c_full_path) catch streamer.MediaInfo{
        .duration = 2799.0,
        .codec_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"",
        .audio_tracks = &[_]streamer.AudioTrack{},
        .subtitle_tracks = &[_]streamer.SubtitleTrack{},
    };
    defer media_info.deinit(allocator);

    var json_out: std.ArrayList(u8) = .empty;
    defer json_out.deinit(allocator);
    try json_out.appendSlice(allocator, "[");
    for (media_info.audio_tracks, 0..) |track, i| {
        if (i > 0) try json_out.appendSlice(allocator, ",");

        var safe_label: std.ArrayList(u8) = .empty;
        defer safe_label.deinit(allocator);
        for (track.label) |ch| {
            if (ch == '"' or ch == '\\') {
                try safe_label.append(allocator, '\\');
            }
            try safe_label.append(allocator, ch);
        }

        const track_str = try std.fmt.allocPrint(allocator, "{{\"id\":{},\"label\":\"{s}\"}}", .{ track.id, safe_label.items });
        try json_out.appendSlice(allocator, track_str);
    }
    try json_out.appendSlice(allocator, "]");

    var sub_json_out: std.ArrayList(u8) = .empty;
    defer sub_json_out.deinit(allocator);
    try sub_json_out.appendSlice(allocator, "[");
    for (media_info.subtitle_tracks, 0..) |track, i| {
        if (i > 0) try sub_json_out.appendSlice(allocator, ",");

        var safe_label: std.ArrayList(u8) = .empty;
        defer safe_label.deinit(allocator);
        for (track.label) |ch| {
            if (ch == '"' or ch == '\\') {
                try safe_label.append(allocator, '\\');
            }
            try safe_label.append(allocator, ch);
        }

        var safe_lang: std.ArrayList(u8) = .empty;
        defer safe_lang.deinit(allocator);
        for (track.language) |ch| {
            if (ch == '"' or ch == '\\') {
                try safe_lang.append(allocator, '\\');
            }
            try safe_lang.append(allocator, ch);
        }

        const track_str = try std.fmt.allocPrint(allocator, "{{\"id\":{},\"label\":\"{s}\",\"language\":\"{s}\"}}", .{ track.id, safe_label.items, safe_lang.items });
        try sub_json_out.appendSlice(allocator, track_str);
    }
    try sub_json_out.appendSlice(allocator, "]");

    const start_opt = utils.parseQueryFloat(target, "start");
    const resume_pos = if (start_opt) |s| s else if (movie_id != null)
        logging_mod.getPlaybackProgress(logs_database, username, movie_id.?) catch 0.0
    else
        logging_mod.getEpisodePlaybackProgress(logs_database, username, episode_id.?) catch 0.0;

    const media_query = if (movie_id != null)
        try std.fmt.allocPrint(allocator, "id={d}", .{movie_id.?})
    else
        try std.fmt.allocPrint(allocator, "episode_id={d}", .{episode_id.?});
    defer allocator.free(media_query);

    var media_title: []const u8 = "Sratim Media";
    var free_title = false;
    defer if (free_title) allocator.free(media_title);

    if (movie_id) |mid| {
        var stmt = database.prepare("SELECT COALESCE(title, clean_name) FROM movies WHERE id = ?1;") catch null;
        if (stmt) |*s| {
            defer s.finalize();
            s.bindInt64(1, mid) catch {};
            if ((s.step() catch .done) == .row) {
                if (s.columnText(0)) |t| {
                    media_title = try allocator.dupe(u8, t);
                    free_title = true;
                }
            }
        }
    } else if (episode_id) |eid| {
        var stmt = database.prepare(
            \\SELECT COALESCE(e.title, s.title || ' S' || e.season || 'E' || e.episode)
            \\FROM episodes e JOIN shows s ON e.show_id = s.id WHERE e.id = ?1;
        ) catch null;
        if (stmt) |*s| {
            defer s.finalize();
            s.bindInt64(1, eid) catch {};
            if ((s.step() catch .done) == .row) {
                if (s.columnText(0)) |t| {
                    media_title = try allocator.dupe(u8, t);
                    free_title = true;
                }
            }
        }
    }

    const lan_ip_opt = utils.getLanIp(allocator) catch null;
    const lan_ip = lan_ip_opt orelse "";
    defer if (lan_ip_opt) |ip| allocator.free(ip);

    const html_content = try html.generatePlayerHtml(allocator, media_query, media_info.duration, media_info.codec_str, json_out.items, sub_json_out.items, resume_pos, media_title, lan_ip);

    try request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}
