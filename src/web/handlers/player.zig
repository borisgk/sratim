const std = @import("std");
const db_mod = @import("../../db/db.zig");
const library_mod = @import("../../db/library.zig");
const metadata_mod = @import("../../db/metadata.zig");
const logging_mod = @import("../../db/logging.zig");
const streamer = @import("../../media/streamer.zig");
const html = @import("../../core/html.zig");

/// Parse an integer query parameter by name from a URL target string.
pub fn parseQueryInt(comptime T: type, target: []const u8, name: []const u8) ?T {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            return std.fmt.parseInt(T, param[name.len + 1 ..], 10) catch null;
        }
    }
    return null;
}

/// Parse a float query parameter by name from a URL target string.
pub fn parseQueryFloat(target: []const u8, name: []const u8) ?f64 {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            return std.fmt.parseFloat(f64, param[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

pub const ResolvedMedia = struct {
    resolved_path: []const u8,
    file_path: []const u8,
};

/// Resolves a media file's absolute path from its database ID with path traversal checks.
pub fn resolveMediaPath(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    info_opt: ?metadata_mod.MovieInfo,
    working_folder: []const u8,
) !?ResolvedMedia {
    if (info_opt == null) return null;
    const media_info = info_opt.?;

    var base_path = try allocator.dupe(u8, working_folder);
    if (library_mod.getLibraryById(database, allocator, media_info.library_id) catch null) |lib| {
        allocator.free(base_path);
        base_path = try allocator.dupe(u8, lib.path);
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, media_info.file_path });
    const resolved_path = try std.fs.path.resolve(allocator, &[_][]const u8{full_path});
    const abs_base = try std.fs.path.resolve(allocator, &[_][]const u8{base_path});
    allocator.free(base_path);

    if (!std.mem.startsWith(u8, resolved_path, abs_base)) {
        return error.PathTraversal;
    }

    return ResolvedMedia{
        .resolved_path = resolved_path,
        .file_path = media_info.file_path,
    };
}

/// Handles the HTML Player page endpoint (/player).
pub fn handlePlayer(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    username: []const u8,
    working_folder: []const u8,
) !void {
    const target = request.head.target;
    const movie_id = parseQueryInt(i64, target, "id");
    const episode_id = parseQueryInt(i64, target, "episode_id");

    if (movie_id == null and episode_id == null) {
        try request.respond("Missing movie id or episode id parameter", .{ .status = .bad_request });
        return;
    }

    const media_info_opt = if (movie_id != null)
        metadata_mod.getMovieInfoById(database, allocator, movie_id.?) catch null
    else
        metadata_mod.getEpisodeInfoById(database, allocator, episode_id.?) catch null;

    const resolved = resolveMediaPath(database, allocator, media_info_opt, working_folder) catch |err| {
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

    const media_info = streamer.getMediaInfo(allocator, c_full_path) catch streamer.MediaInfo{
        .duration = 2799.0,
        .codec_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"",
        .audio_tracks = &[_]streamer.AudioTrack{},
    };

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

    const start_opt = parseQueryFloat(target, "start");
    const resume_pos = if (start_opt) |s| s else if (movie_id != null)
        logging_mod.getPlaybackProgress(logs_database, username, movie_id.?) catch 0.0
    else
        logging_mod.getEpisodePlaybackProgress(logs_database, username, episode_id.?) catch 0.0;

    const media_query = if (movie_id != null)
        try std.fmt.allocPrint(allocator, "id={d}", .{movie_id.?})
    else
        try std.fmt.allocPrint(allocator, "episode_id={d}", .{episode_id.?});
    defer allocator.free(media_query);

    const html_content = try html.generatePlayerHtml(allocator, media_query, media_info.duration, media_info.codec_str, json_out.items, resume_pos);

    try request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}

/// Handles the media stream endpoint (/stream).
pub fn handleStream(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    working_folder: []const u8,
    resp_buf: []u8,
) !void {
    const target = request.head.target;
    const movie_id = parseQueryInt(i64, target, "id");
    const episode_id = parseQueryInt(i64, target, "episode_id");

    if (movie_id == null and episode_id == null) {
        try request.respond("Missing id or episode_id parameter", .{ .status = .bad_request });
        return;
    }

    const media_info_opt = if (movie_id != null)
        metadata_mod.getMovieInfoById(database, allocator, movie_id.?) catch null
    else
        metadata_mod.getEpisodeInfoById(database, allocator, episode_id.?) catch null;

    const resolved = resolveMediaPath(database, allocator, media_info_opt, working_folder) catch |err| {
        if (err == error.PathTraversal) {
            try request.respond("Forbidden", .{ .status = .forbidden });
        } else {
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        }
        return;
    };
    if (resolved == null) {
        try request.respond("Movie not found", .{ .status = .not_found });
        return;
    }

    const start_time = parseQueryFloat(target, "start") orelse 0;
    const audio_idx = parseQueryInt(c_int, target, "audio") orelse -1;

    var resp = try request.respondStreaming(resp_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "video/mp4" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
        },
    });

    var stream_ctx = streamer.HttpStreamContext{ .writer = &resp };
    streamer.streamMedia(resolved.?.resolved_path, start_time, audio_idx, &stream_ctx) catch |e| {
        if (e != error.ConnectionDropped) {
            std.debug.print("Stream error: {}\n", .{e});
        }
        return;
    };

    try resp.end();
}
