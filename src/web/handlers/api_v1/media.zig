const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const session_mod = @import("../../../db/session.zig");
const logging_mod = @import("../../../db/logging.zig");
const common = @import("../player/common.zig");
const streamer = @import("../../../media/streamer.zig");
const config_mod = @import("../../../config.zig");
const utils = @import("../../utils.zig");

fn appendAudioTracksJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tracks: []const streamer.AudioTrack,
) !void {
    try out.appendSlice(allocator, "[");
    for (tracks, 0..) |track, i| {
        if (i > 0) try out.appendSlice(allocator, ",");
        const escaped_label = try utils.escapeJsonAlloc(allocator, track.label);
        defer allocator.free(escaped_label);
        const escaped_codec = try utils.escapeJsonAlloc(allocator, track.codec);
        defer allocator.free(escaped_codec);

        const item = try std.fmt.allocPrint(
            allocator,
            "{{\"id\":{d},\"label\":\"{s}\",\"codec\":\"{s}\"}}",
            .{ track.id, escaped_label, escaped_codec },
        );
        defer allocator.free(item);
        try out.appendSlice(allocator, item);
    }
    try out.appendSlice(allocator, "]");
}

pub fn handleGetMovie(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    io: std.Io,
    session_info: session_mod.SessionInfo,
) !void {
    if (request.head.method != .GET) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    const movie_id = utils.parseQueryInt(i64, request.head.target, "id") orelse {
        try request.respond("{\"success\":false,\"error\":\"Missing movie id\"}", .{ .status = .bad_request });
        return;
    };

    const cat = database.catalog orelse {
        try request.respond("{\"success\":false,\"error\":\"Catalog not configured\"}", .{ .status = .internal_server_error });
        return;
    };

    const mov_opt = try cat.getMovieById(allocator, movie_id);
    if (mov_opt == null or !mov_opt.?.is_present) {
        try request.respond("{\"success\":false,\"error\":\"Movie not found\"}", .{ .status = .not_found });
        return;
    }
    const mov = mov_opt.?;
    defer {
        var mut = mov;
        mut.deinit(allocator);
    }

    const id = mov.id;
    const library_id = mov.library_id;
    const file_path = mov.file_path;
    const clean_name = mov.clean_name;
    const title_opt = mov.title;
    const overview = mov.overview orelse "";
    const poster_path = mov.poster_path orelse "";
    const backdrop_path = mov.backdrop_path orelse "";
    const release_date = mov.release_date orelse "";
    var tmdb_id_buf: [32]u8 = undefined;
    const tmdb_id = if (mov.tmdb_id) |tid| std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "" else "";

    var runtime: u32 = 0;
    var file_size: u64 = 0;
    var audio_tracks_json = std.ArrayList(u8).empty;
    defer audio_tracks_json.deinit(allocator);

    if (common.resolveMediaPath(database, allocator, .{ .library_id = library_id, .file_path = file_path }) catch null) |resolved| {
        defer allocator.free(resolved.resolved_path);
        const file = std.Io.Dir.cwd().openFile(io, resolved.resolved_path, .{ .mode = .read_only }) catch null;
        if (file) |f| {
            defer f.close(io);
            if (f.stat(io) catch null) |st| {
                file_size = st.size;
            }
        }

        const c_path = allocator.dupeSentinel(u8, resolved.resolved_path, 0) catch null;
        if (c_path) |cp| {
            defer allocator.free(cp);
            if (streamer.getMediaInfo(allocator, io, cp, config.media_engine.metadata) catch null) |media_info| {
                defer media_info.deinit(allocator);
                if (media_info.duration > 0) {
                    runtime = @as(u32, @intFromFloat(media_info.duration / 60.0));
                }
                try appendAudioTracksJson(allocator, &audio_tracks_json, media_info.audio_tracks);
            }
        }
    }
    if (audio_tracks_json.items.len == 0) {
        try audio_tracks_json.appendSlice(allocator, "[]");
    }

    const display_title = if (title_opt) |t| t else clean_name;
    const resume_pos = logging_mod.getPlaybackProgress(database, session_info.username, movie_id) catch 0.0;

    var escaped_title = std.ArrayList(u8).empty;
    defer escaped_title.deinit(allocator);
    for (display_title) |ch| {
        switch (ch) {
            '"' => try escaped_title.appendSlice(allocator, "\\\""),
            '\\' => try escaped_title.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_title.appendSlice(allocator, "\\n"),
            '\r' => try escaped_title.appendSlice(allocator, "\\r"),
            '\t' => try escaped_title.appendSlice(allocator, "\\t"),
            else => try escaped_title.append(allocator, ch),
        }
    }

    var escaped_overview = std.ArrayList(u8).empty;
    defer escaped_overview.deinit(allocator);
    for (overview) |ch| {
        switch (ch) {
            '"' => try escaped_overview.appendSlice(allocator, "\\\""),
            '\\' => try escaped_overview.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_overview.appendSlice(allocator, "\\n"),
            '\r' => try escaped_overview.appendSlice(allocator, "\\r"),
            '\t' => try escaped_overview.appendSlice(allocator, "\\t"),
            else => try escaped_overview.append(allocator, ch),
        }
    }

    const json = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"movie\":{{\"id\":{d},\"library_id\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"poster_path\":\"{s}\",\"backdrop_path\":\"{s}\",\"release_date\":\"{s}\",\"tmdb_id\":\"{s}\",\"file_size\":{d},\"file_path\":\"{s}\",\"runtime\":{d},\"resume_position\":{d:.1},\"audio_tracks\":{s}}}}}", .{ id, library_id, escaped_title.items, escaped_overview.items, poster_path, backdrop_path, release_date, tmdb_id, file_size, file_path, runtime, resume_pos, audio_tracks_json.items });
    defer allocator.free(json);

    try request.respond(json, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

pub fn handleGetShow(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    io: std.Io,
    session_info: session_mod.SessionInfo,
) !void {
    if (request.head.method != .GET) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    const show_id = utils.parseQueryInt(i64, request.head.target, "id") orelse {
        try request.respond("{\"success\":false,\"error\":\"Missing show id\"}", .{ .status = .bad_request });
        return;
    };

    const cat = database.catalog orelse {
        try request.respond("{\"success\":false,\"error\":\"Catalog not configured\"}", .{ .status = .internal_server_error });
        return;
    };

    const show_opt = try cat.getShowById(allocator, show_id);
    if (show_opt == null or !show_opt.?.is_present) {
        try request.respond("{\"success\":false,\"error\":\"Show not found\"}", .{ .status = .not_found });
        return;
    }
    const show = show_opt.?;
    defer {
        var mut = show;
        mut.deinit(allocator);
    }

    const title = show.title;
    const overview = show.overview orelse "";
    const poster_path = show.poster_path orelse "";
    const backdrop_path = show.backdrop_path orelse "";
    const library_id = show.library_id;
    var tmdb_id_buf: [32]u8 = undefined;
    const tmdb_id = if (show.tmdb_id) |tid| std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "" else "";

    var escaped_title = std.ArrayList(u8).empty;
    defer escaped_title.deinit(allocator);
    for (title) |c| {
        switch (c) {
            '"' => try escaped_title.appendSlice(allocator, "\\\""),
            '\\' => try escaped_title.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_title.appendSlice(allocator, "\\n"),
            '\r' => try escaped_title.appendSlice(allocator, "\\r"),
            '\t' => try escaped_title.appendSlice(allocator, "\\t"),
            else => try escaped_title.append(allocator, c),
        }
    }

    var escaped_overview = std.ArrayList(u8).empty;
    defer escaped_overview.deinit(allocator);
    for (overview) |c| {
        switch (c) {
            '"' => try escaped_overview.appendSlice(allocator, "\\\""),
            '\\' => try escaped_overview.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_overview.appendSlice(allocator, "\\n"),
            '\r' => try escaped_overview.appendSlice(allocator, "\\r"),
            '\t' => try escaped_overview.appendSlice(allocator, "\\t"),
            else => try escaped_overview.append(allocator, c),
        }
    }

    const episodes = try cat.getEpisodesByShow(allocator, show_id);
    defer {
        for (episodes) |*ep| {
            var mut = ep.*;
            mut.deinit(allocator);
        }
        allocator.free(episodes);
    }

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"success\":true,\"show\":{");
    const show_header = try std.fmt.allocPrint(allocator, "\"id\":{d},\"library_id\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"poster_path\":\"{s}\",\"backdrop_path\":\"{s}\",\"tmdb_id\":\"{s}\",\"episodes\":[", .{ show_id, library_id, escaped_title.items, escaped_overview.items, poster_path, backdrop_path, tmdb_id });
    defer allocator.free(show_header);
    try json.appendSlice(allocator, show_header);

    var first_ep = true;
    for (episodes) |ep| {
        if (!ep.is_present) continue;
        if (!first_ep) try json.appendSlice(allocator, ",");
        first_ep = false;

        const ep_id = ep.id;
        const file_path = ep.file_path;
        const season = ep.season;
        const episode = ep.episode;
        const ep_title_opt = ep.title;
        const ep_overview_opt = ep.overview;
        const ep_still_path_opt = ep.still_path;
        const ep_db_file_size = ep.file_size;

        var ep_file_size: u64 = @intCast(@max(0, ep_db_file_size));
        var ep_runtime: u32 = 0;
        var ep_audio_tracks_json = std.ArrayList(u8).empty;
        defer ep_audio_tracks_json.deinit(allocator);

        if (common.resolveMediaPath(database, allocator, .{ .library_id = library_id, .file_path = file_path }) catch null) |resolved| {
            defer allocator.free(resolved.resolved_path);

            if (std.Io.Dir.cwd().openFile(io, resolved.resolved_path, .{ .mode = .read_only }) catch null) |file| {
                defer file.close(io);
                if (file.stat(io) catch null) |st| {
                    ep_file_size = st.size;
                }
            }

            const c_path = allocator.dupeSentinel(u8, resolved.resolved_path, 0) catch null;
            if (c_path) |cp| {
                defer allocator.free(cp);
                if (streamer.getMediaInfo(allocator, io, cp, config.media_engine.metadata) catch null) |media_info| {
                    defer media_info.deinit(allocator);
                    if (media_info.duration > 0) {
                        ep_runtime = @as(u32, @intFromFloat(media_info.duration / 60.0));
                    }
                    try appendAudioTracksJson(allocator, &ep_audio_tracks_json, media_info.audio_tracks);
                }
            }
        }
        if (ep_audio_tracks_json.items.len == 0) {
            try ep_audio_tracks_json.appendSlice(allocator, "[]");
        }

        const basename = std.fs.path.basename(file_path);
        const display_title = if (ep_title_opt) |t| t else basename;
        const display_overview = if (ep_overview_opt) |o| o else "";
        const still_path = if (ep_still_path_opt) |s| s else "";

        var esc_ep_title = std.ArrayList(u8).empty;
        defer esc_ep_title.deinit(allocator);
        for (display_title) |c| {
            switch (c) {
                '"' => try esc_ep_title.appendSlice(allocator, "\\\""),
                '\\' => try esc_ep_title.appendSlice(allocator, "\\\\"),
                '\n' => try esc_ep_title.appendSlice(allocator, "\\n"),
                '\r' => try esc_ep_title.appendSlice(allocator, "\\r"),
                '\t' => try esc_ep_title.appendSlice(allocator, "\\t"),
                else => try esc_ep_title.append(allocator, c),
            }
        }

        var esc_ep_overview = std.ArrayList(u8).empty;
        defer esc_ep_overview.deinit(allocator);
        for (display_overview) |c| {
            switch (c) {
                '"' => try esc_ep_overview.appendSlice(allocator, "\\\""),
                '\\' => try esc_ep_overview.appendSlice(allocator, "\\\\"),
                '\n' => try esc_ep_overview.appendSlice(allocator, "\\n"),
                '\r' => try esc_ep_overview.appendSlice(allocator, "\\r"),
                '\t' => try esc_ep_overview.appendSlice(allocator, "\\t"),
                else => try esc_ep_overview.append(allocator, c),
            }
        }

        const ep_resume_pos = logging_mod.getEpisodePlaybackProgress(database, session_info.username, ep_id) catch 0.0;

        const ep_json = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"season\":{d},\"episode\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"still_path\":\"{s}\",\"file_size\":{d},\"runtime\":{d},\"resume_position\":{d:.1},\"audio_tracks\":{s}}}", .{ ep_id, season, episode, esc_ep_title.items, esc_ep_overview.items, still_path, ep_file_size, ep_runtime, ep_resume_pos, ep_audio_tracks_json.items });
        defer allocator.free(ep_json);
        try json.appendSlice(allocator, ep_json);
    }

    try json.appendSlice(allocator, "]}}");

    try request.respond(json.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

pub fn handleGetRecentlyWatched(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    session_info: session_mod.SessionInfo,
) !void {
    if (request.head.method != .GET) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    const limit = utils.parseQueryInt(usize, request.head.target, "limit") orelse 20;

    const cat = database.catalog orelse {
        try request.respond("{\"success\":false,\"error\":\"Catalog not configured\"}", .{ .status = .internal_server_error });
        return;
    };

    const recent_items = logging_mod.getRecentlyWatched(database, allocator, session_info.username, limit) catch |err| {
        std.debug.print("Failed to get recently watched: {any}\n", .{err});
        try request.respond("{\"success\":false,\"error\":\"Failed to query recently watched\"}", .{ .status = .internal_server_error });
        return;
    };
    defer allocator.free(recent_items);

    var json_buf = std.ArrayList(u8).empty;
    defer json_buf.deinit(allocator);

    try json_buf.appendSlice(allocator, "{\"success\":true,\"items\":[");

    var first = true;
    for (recent_items) |item| {
        if (item.media_type == .movie) {
            const mov_opt = cat.getMovieById(allocator, item.item_id) catch null;
            if (mov_opt) |mov| {
                defer {
                    var mut = mov;
                    mut.deinit(allocator);
                }
                if (mov.is_present) {
                    if (!first) try json_buf.append(allocator, ',');
                    first = false;

                    const title = mov.title orelse mov.clean_name;
                    const poster = mov.poster_path orelse "";
                    const backdrop = mov.backdrop_path orelse "";
                    const progress_pct: f64 = if (item.duration > 0.0)
                        std.math.clamp((item.position / item.duration) * 100.0, 0.0, 100.0)
                    else
                        0.0;

                    const escaped_title = try utils.escapeJsonAlloc(allocator, title);
                    defer allocator.free(escaped_title);
                    const escaped_poster = try utils.escapeJsonAlloc(allocator, poster);
                    defer allocator.free(escaped_poster);
                    const escaped_backdrop = try utils.escapeJsonAlloc(allocator, backdrop);
                    defer allocator.free(escaped_backdrop);

                    const entry = try std.fmt.allocPrint(
                        allocator,
                        "{{\"id\":{d},\"type\":\"movie\",\"title\":\"{s}\",\"poster_path\":\"{s}\",\"backdrop_path\":\"{s}\",\"position\":{d:.1},\"duration\":{d:.1},\"progress_percent\":{d:.1},\"updated_at\":{d}}}",
                        .{ item.item_id, escaped_title, escaped_poster, escaped_backdrop, item.position, item.duration, progress_pct, item.updated_at },
                    );
                    defer allocator.free(entry);
                    try json_buf.appendSlice(allocator, entry);
                }
            }
        } else if (item.media_type == .episode) {
            const ep_opt = cat.getEpisodeById(allocator, item.item_id) catch null;
            if (ep_opt) |ep| {
                defer {
                    var mut = ep;
                    mut.deinit(allocator);
                }
                if (ep.is_present) {
                    const sh_opt = cat.getShowById(allocator, ep.show_id) catch null;
                    if (sh_opt) |sh| {
                        defer {
                            var mut_sh = sh;
                            mut_sh.deinit(allocator);
                        }
                        if (sh.is_present) {
                            if (!first) try json_buf.append(allocator, ',');
                            first = false;

                            const show_title = sh.title;
                            const ep_title = ep.title orelse "";
                            // Prefer the high-quality vertical series poster (sh.poster_path) over the episode still
                            const poster = sh.poster_path orelse ep.still_path orelse "";
                            const show_poster = sh.poster_path orelse "";
                            const backdrop = sh.backdrop_path orelse "";
                            const progress_pct: f64 = if (item.duration > 0.0)
                                std.math.clamp((item.position / item.duration) * 100.0, 0.0, 100.0)
                            else
                                0.0;

                            const escaped_show = try utils.escapeJsonAlloc(allocator, show_title);
                            defer allocator.free(escaped_show);
                            const escaped_ep = try utils.escapeJsonAlloc(allocator, ep_title);
                            defer allocator.free(escaped_ep);
                            const escaped_poster = try utils.escapeJsonAlloc(allocator, poster);
                            defer allocator.free(escaped_poster);
                            const escaped_show_poster = try utils.escapeJsonAlloc(allocator, show_poster);
                            defer allocator.free(escaped_show_poster);
                            const escaped_backdrop = try utils.escapeJsonAlloc(allocator, backdrop);
                            defer allocator.free(escaped_backdrop);

                            const entry = try std.fmt.allocPrint(
                                allocator,
                                "{{\"id\":{d},\"type\":\"episode\",\"show_id\":{d},\"show_title\":\"{s}\",\"title\":\"{s}\",\"season\":{d},\"episode\":{d},\"poster_path\":\"{s}\",\"show_poster_path\":\"{s}\",\"backdrop_path\":\"{s}\",\"position\":{d:.1},\"duration\":{d:.1},\"progress_percent\":{d:.1},\"updated_at\":{d}}}",
                                .{ item.item_id, ep.show_id, escaped_show, escaped_ep, ep.season, ep.episode, escaped_poster, escaped_show_poster, escaped_backdrop, item.position, item.duration, progress_pct, item.updated_at },
                            );
                            defer allocator.free(entry);
                            try json_buf.appendSlice(allocator, entry);
                        }
                    }
                }
            }
        }
    }

    try json_buf.appendSlice(allocator, "]}");

    try request.respond(json_buf.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}
