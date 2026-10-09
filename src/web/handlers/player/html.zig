const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const logging_mod = @import("../../../db/logging.zig");
const streamer = @import("../../../media/streamer.zig");
const config_mod = @import("../../../config.zig");
const template_engine = @import("../../../core/template.zig");
const utils = @import("../../utils.zig");
const common = @import("common.zig");

const player_js_tmpl: []const u8 = @embedFile("../../templates/player.js");
const stats_js_tmpl: []const u8 = @embedFile("../../templates/stats.js");
const player_html_tmpl: []const u8 = @embedFile("../../templates/player.html");
const player_css: []const u8 = @embedFile("../../templates/player.css");
const stats_css: []const u8 = @embedFile("../../templates/stats.css");

/// Handles the HTML Player page endpoint (/player).
pub fn handlePlayer(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    username: []const u8,
    config: *const config_mod.Config,
    io: std.Io,
) !void {
    const target = request.head.target;
    const movie_id = utils.parseQueryInt(i64, target, "id");
    const episode_id = utils.parseQueryInt(i64, target, "episode_id");

    var res_media = (try common.resolveRequestMedia(request, allocator, database)) orelse return;
    defer res_media.deinit(allocator);

    const c_full_path = try allocator.dupeSentinel(u8, res_media.resolved_path, 0);
    defer allocator.free(c_full_path);

    const media_info = streamer.getMediaInfo(allocator, io, c_full_path, config.media_engine.metadata) catch streamer.MediaInfo{
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

        var safe_codec: std.ArrayList(u8) = .empty;
        defer safe_codec.deinit(allocator);
        for (track.codec) |ch| {
            if (ch == '"' or ch == '\\') {
                try safe_codec.append(allocator, '\\');
            }
            try safe_codec.append(allocator, ch);
        }

        const track_str = try std.fmt.allocPrint(allocator, "{{\"id\":{},\"label\":\"{s}\",\"codec\":\"{s}\"}}", .{ track.id, safe_label.items, safe_codec.items });
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
    var resume_pos = if (start_opt) |s| s else if (movie_id != null)
        logging_mod.getPlaybackProgress(database, username, movie_id.?) catch 0.0
    else
        logging_mod.getEpisodePlaybackProgress(database, username, episode_id.?) catch 0.0;

    if (resume_pos < 0.0 or (media_info.duration > 0.0 and (resume_pos >= media_info.duration - 3.0 or resume_pos >= media_info.duration * 0.95))) {
        resume_pos = 0.0;
    }

    const media_query = if (movie_id != null)
        try std.fmt.allocPrint(allocator, "id={d}", .{movie_id.?})
    else
        try std.fmt.allocPrint(allocator, "episode_id={d}", .{episode_id.?});
    defer allocator.free(media_query);

    var media_title: []const u8 = "Sratim Media";
    var free_title = false;
    defer if (free_title) allocator.free(media_title);

    var return_url: []const u8 = "/";
    var free_return_url = false;
    defer if (free_return_url) allocator.free(return_url);

    if (movie_id) |mid| {
        return_url = try std.fmt.allocPrint(allocator, "/details?id={d}", .{mid});
        free_return_url = true;
        if (database.catalog) |cat| {
            if (cat.getMovieById(allocator, mid) catch null) |m| {
                defer {
                    var mut = m;
                    mut.deinit(allocator);
                }
                media_title = try allocator.dupe(u8, m.title orelse m.clean_name);
                free_title = true;
            }
        }
    } else if (episode_id) |eid| {
        if (database.catalog) |cat| {
            if (cat.getEpisodeById(allocator, eid) catch null) |ep| {
                defer {
                    var mut = ep;
                    mut.deinit(allocator);
                }
                return_url = try std.fmt.allocPrint(allocator, "/show?id={d}", .{ep.show_id});
                free_return_url = true;
                if (ep.title) |t| {
                    media_title = try allocator.dupe(u8, t);
                    free_title = true;
                } else if (cat.getShowById(allocator, ep.show_id) catch null) |sh| {
                    defer {
                        var mut_sh = sh;
                        mut_sh.deinit(allocator);
                    }
                    media_title = try std.fmt.allocPrint(allocator, "{s} S{d}E{d}", .{ sh.title, ep.season, ep.episode });
                    free_title = true;
                }
            }
        }
    }

    const lan_ip_opt = utils.getLanIp(allocator) catch null;
    const lan_ip = lan_ip_opt orelse "";
    defer if (lan_ip_opt) |ip| allocator.free(ip);

    const streamer_mode = if (config.media_engine.streamer == .native) "native-fmp4" else "ffmpeg";
    const audio_mode = if (config.media_engine.audio_transcoder == .native) "native-aac" else "ffmpeg";

    const html_content = try generatePlayerHtml(
        allocator,
        media_query,
        media_info.duration,
        media_info.codec_str,
        json_out.items,
        sub_json_out.items,
        resume_pos,
        media_title,
        lan_ip,
        streamer_mode,
        audio_mode,
        return_url,
    );

    try request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}

fn generatePlayerHtml(
    allocator: std.mem.Allocator,
    media_query: []const u8,
    duration: f64,
    codec_str: []const u8,
    audio_tracks_json: []const u8,
    subtitle_tracks_json: []const u8,
    start_position: f64,
    media_title: []const u8,
    server_lan_ip: []const u8,
    streamer_mode: []const u8,
    audio_transcoder_mode: []const u8,
    return_url: []const u8,
) ![]u8 {
    const min = @as(u32, @intFromFloat(duration)) / 60;
    const sec = @as(u32, @intFromFloat(duration)) % 60;
    const time_str = try std.fmt.allocPrint(allocator, "{d}:{d:0>2}", .{ min, sec });
    defer allocator.free(time_str);

    var title_escaped: std.ArrayList(u8) = .empty;
    defer title_escaped.deinit(allocator);
    try utils.escapeForJs(&title_escaped, allocator, media_title);

    var title_html: std.ArrayList(u8) = .empty;
    defer title_html.deinit(allocator);
    try utils.escapeHtml(&title_html, allocator, media_title);

    var return_url_escaped: std.ArrayList(u8) = .empty;
    defer return_url_escaped.deinit(allocator);
    try utils.escapeForJs(&return_url_escaped, allocator, return_url);

    const rendered_js = try template_engine.render(allocator, player_js_tmpl, .{
        .DURATION = duration,
        .MEDIA_QUERY = media_query,
        .CODEC_STR = codec_str,
        .AUDIO_TRACKS_JSON = audio_tracks_json,
        .SUBTITLE_TRACKS_JSON = subtitle_tracks_json,
        .START_POSITION = start_position,
        .MEDIA_TITLE = title_escaped.items,
        .SERVER_LAN_IP = server_lan_ip,
        .RETURN_URL = return_url_escaped.items,
    });
    defer allocator.free(rendered_js);

    const rendered_stats_js = try template_engine.render(allocator, stats_js_tmpl, .{
        .STREAMER_MODE = streamer_mode,
        .AUDIO_TRANSCODER_MODE = audio_transcoder_mode,
    });
    defer allocator.free(rendered_stats_js);

    return template_engine.render(allocator, player_html_tmpl, .{
        .PLAYER_CSS = player_css,
        .STATS_CSS = stats_css,
        .PLAYER_JS = rendered_js,
        .STATS_JS = rendered_stats_js,
        .TIME_STR = time_str,
        .MEDIA_TITLE = title_html.items,
        .RETURN_URL = return_url,
    });
}
