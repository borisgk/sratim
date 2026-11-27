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
    _ = config;
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

    var duration_sec: f64 = 0.0;
    var runtime: u32 = 0;
    var file_size: u64 = @intCast(@max(0, mov.file_size));
    var audio_tracks_json = std.ArrayList(u8).empty;
    defer audio_tracks_json.deinit(allocator);

    if (mov.duration_sec > 0.0 and mov.audio_tracks_json != null) {
        duration_sec = mov.duration_sec;
        runtime = @as(u32, @intFromFloat(mov.duration_sec / 60.0));
        try audio_tracks_json.appendSlice(allocator, mov.audio_tracks_json.?);
    } else if (common.resolveMediaPath(database, allocator, .{ .library_id = library_id, .file_path = file_path }) catch null) |resolved| {
        defer allocator.free(resolved.resolved_path);
        if (file_size == 0) {
            if (std.Io.Dir.cwd().statFile(io, resolved.resolved_path, .{}) catch null) |st| {
                file_size = st.size;
            }
        }

        const c_path = allocator.dupeSentinel(u8, resolved.resolved_path, 0) catch null;
        if (c_path) |cp| {
            defer allocator.free(cp);
            if (streamer.getMediaInfoFast(allocator, io, cp) catch null) |media_info| {
                defer media_info.deinit(allocator);
                if (media_info.duration > 0) {
                    duration_sec = media_info.duration;
                    runtime = @as(u32, @intFromFloat(media_info.duration / 60.0));
                }
                try appendAudioTracksJson(allocator, &audio_tracks_json, media_info.audio_tracks);
                if (duration_sec > 0.0) {
                    cat.cacheMovieMediaInfo(id, @intCast(file_size), duration_sec, audio_tracks_json.items) catch {};
                    cat.snapshot() catch {};
                }
            }
        }
    }
    if (audio_tracks_json.items.len == 0) {
        try audio_tracks_json.appendSlice(allocator, "[]");
    }

    const display_title = if (title_opt) |t| t else clean_name;
    const resume_pos = logging_mod.getPlaybackProgress(database, session_info.username, movie_id) catch 0.0;

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try json.ensureTotalCapacity(allocator, 512 + overview.len + audio_tracks_json.items.len);

    var num_buf: [128]u8 = undefined;
    try json.appendSlice(allocator, try std.fmt.bufPrint(
        &num_buf,
        "{{\"success\":true,\"movie\":{{\"id\":{d},\"library_id\":{d},\"title\":\"",
        .{ id, library_id },
    ));
    try utils.escapeJsonString(&json, allocator, display_title);
    try json.appendSlice(allocator, "\",\"overview\":\"");
    try utils.escapeJsonString(&json, allocator, overview);
    try json.appendSlice(allocator, "\",\"poster_path\":\"");
    try utils.escapeJsonString(&json, allocator, poster_path);
    try json.appendSlice(allocator, "\",\"backdrop_path\":\"");
    try utils.escapeJsonString(&json, allocator, backdrop_path);
    try json.appendSlice(allocator, "\",\"release_date\":\"");
    try utils.escapeJsonString(&json, allocator, release_date);
    try json.appendSlice(allocator, "\",\"tmdb_id\":\"");
    try json.appendSlice(allocator, tmdb_id);
    try json.appendSlice(allocator, try std.fmt.bufPrint(&num_buf, "\",\"file_size\":{d},\"file_path\":\"", .{file_size}));
    try utils.escapeJsonString(&json, allocator, file_path);
    try json.appendSlice(allocator, try std.fmt.bufPrint(
        &num_buf,
        "\",\"runtime\":{d},\"duration_sec\":{d:.2},\"resume_position\":{d:.1},\"audio_tracks\":",
        .{ runtime, duration_sec, resume_pos },
    ));
    try json.appendSlice(allocator, audio_tracks_json.items);
    try json.appendSlice(allocator, "}}");

    try request.respond(json.items, .{
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

    _ = config;
    const probe_files = (utils.parseQueryInt(u8, request.head.target, "probe") orelse 0) == 1;

    const title = show.title;
    const overview = show.overview orelse "";
    const poster_path = show.poster_path orelse "";
    const backdrop_path = show.backdrop_path orelse "";
    const library_id = show.library_id;
    var tmdb_id_buf: [32]u8 = undefined;
    const tmdb_id = if (show.tmdb_id) |tid| std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "" else "";

    const episodes = try cat.getEpisodesByShow(allocator, show_id);
    defer {
        for (episodes) |*ep| {
            var mut = ep.*;
            mut.deinit(allocator);
        }
        allocator.free(episodes);
    }

    // Single read-lock fetch of all episode resume positions for this user
    var progress_map = std.AutoHashMap(i64, f64).init(allocator);
    defer progress_map.deinit();
    if (logging_mod.getEpisodeProgressForUser(database, allocator, session_info.username) catch null) |prog_list| {
        defer allocator.free(prog_list);
        try progress_map.ensureTotalCapacity(@intCast(prog_list.len));
        for (prog_list) |p| {
            progress_map.putAssumeCapacity(p.episode_id, p.position);
        }
    }

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try json.ensureTotalCapacity(allocator, episodes.len * 320 + 512);

    var num_buf: [128]u8 = undefined;
    try json.appendSlice(allocator, try std.fmt.bufPrint(
        &num_buf,
        "{{\"success\":true,\"show\":{{\"id\":{d},\"library_id\":{d},\"title\":\"",
        .{ show_id, library_id },
    ));
    try utils.escapeJsonString(&json, allocator, title);
    try json.appendSlice(allocator, "\",\"overview\":\"");
    try utils.escapeJsonString(&json, allocator, overview);
    try json.appendSlice(allocator, "\",\"poster_path\":\"");
    try utils.escapeJsonString(&json, allocator, poster_path);
    try json.appendSlice(allocator, "\",\"backdrop_path\":\"");
    try utils.escapeJsonString(&json, allocator, backdrop_path);
    try json.appendSlice(allocator, "\",\"tmdb_id\":\"");
    try json.appendSlice(allocator, tmdb_id);
    try json.appendSlice(allocator, "\",\"episodes\":[");

    // Resolve library base path ONCE only if ?probe=1 was explicitly requested
    var lib_opt = if (probe_files) (cat.getLibraryById(allocator, library_id) catch null) else null;
    defer if (lib_opt) |*l| l.deinit(allocator);

    var newly_cached = false;
    var first_ep = true;
    for (episodes) |ep| {
        if (!ep.is_present) continue;
        if (!first_ep) try json.append(allocator, ',');
        first_ep = false;

        var ep_file_size: u64 = @intCast(@max(0, ep.file_size));
        var ep_runtime: u32 = 0;

        var probed_tracks_json = std.ArrayList(u8).empty;
        defer probed_tracks_json.deinit(allocator);
        var tracks_slice: []const u8 = "null";

        if (ep.duration_sec > 0.0 and ep.audio_tracks_json != null) {
            ep_runtime = @as(u32, @intFromFloat(ep.duration_sec / 60.0));
            tracks_slice = ep.audio_tracks_json.?;
        } else if (probe_files and lib_opt != null) {
            if (std.fs.path.join(allocator, &.{ lib_opt.?.path, ep.file_path }) catch null) |full_path| {
                defer allocator.free(full_path);
                if (ep_file_size == 0) {
                    if (std.Io.Dir.cwd().statFile(io, full_path, .{}) catch null) |st| {
                        ep_file_size = st.size;
                    }
                }
                if (allocator.dupeSentinel(u8, full_path, 0) catch null) |cp| {
                    defer allocator.free(cp);
                    if (streamer.getMediaInfoFast(allocator, io, cp) catch null) |media_info| {
                        defer media_info.deinit(allocator);
                        if (media_info.duration > 0) {
                            ep_runtime = @as(u32, @intFromFloat(media_info.duration / 60.0));
                        }
                        try appendAudioTracksJson(allocator, &probed_tracks_json, media_info.audio_tracks);
                        if (media_info.duration > 0.0) {
                            cat.cacheEpisodeMediaInfo(ep.id, @intCast(ep_file_size), media_info.duration, probed_tracks_json.items) catch {};
                            newly_cached = true;
                        }
                    }
                }
            }
            if (probed_tracks_json.items.len == 0) {
                try probed_tracks_json.appendSlice(allocator, "[]");
            }
            tracks_slice = probed_tracks_json.items;
        }

        const basename = std.fs.path.basename(ep.file_path);
        const display_title = ep.title orelse basename;
        const display_overview = ep.overview orelse "";
        const still_path = ep.still_path orelse "";
        const ep_resume_pos = progress_map.get(ep.id) orelse 0.0;

        try json.appendSlice(allocator, try std.fmt.bufPrint(
            &num_buf,
            "{{\"id\":{d},\"season\":{d},\"episode\":{d},\"title\":\"",
            .{ ep.id, ep.season, ep.episode },
        ));
        try utils.escapeJsonString(&json, allocator, display_title);
        try json.appendSlice(allocator, "\",\"overview\":\"");
        try utils.escapeJsonString(&json, allocator, display_overview);
        try json.appendSlice(allocator, "\",\"still_path\":\"");
        try utils.escapeJsonString(&json, allocator, still_path);
        try json.appendSlice(allocator, try std.fmt.bufPrint(
            &num_buf,
            "\",\"file_size\":{d},\"runtime\":{d},\"resume_position\":{d:.1},\"audio_tracks\":",
            .{ ep_file_size, ep_runtime, ep_resume_pos },
        ));
        try json.appendSlice(allocator, tracks_slice);
        try json.append(allocator, '}');
    }

    if (newly_cached) {
        cat.snapshot() catch {};
    }

    try json.appendSlice(allocator, "]}}");

    try request.respond(json.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

pub fn handleGetEpisode(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    io: std.Io,
    session_info: session_mod.SessionInfo,
) !void {
    _ = config;
    if (request.head.method != .GET) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    const episode_id = utils.parseQueryInt(i64, request.head.target, "id") orelse {
        try request.respond("{\"success\":false,\"error\":\"Missing episode id\"}", .{ .status = .bad_request });
        return;
    };

    const cat = database.catalog orelse {
        try request.respond("{\"success\":false,\"error\":\"Catalog not configured\"}", .{ .status = .internal_server_error });
        return;
    };

    const ep_opt = try cat.getEpisodeById(allocator, episode_id);
    if (ep_opt == null or !ep_opt.?.is_present) {
        try request.respond("{\"success\":false,\"error\":\"Episode not found\"}", .{ .status = .not_found });
        return;
    }
    var ep = ep_opt.?;
    defer ep.deinit(allocator);

    const sh_opt = try cat.getShowById(allocator, ep.show_id);
    if (sh_opt == null or !sh_opt.?.is_present) {
        try request.respond("{\"success\":false,\"error\":\"Parent show not found\"}", .{ .status = .not_found });
        return;
    }
    var sh = sh_opt.?;
    defer sh.deinit(allocator);

    var ep_file_size: u64 = @intCast(@max(0, ep.file_size));
    var ep_duration_sec: f64 = 0.0;
    var ep_runtime: u32 = 0;
    var ep_audio_tracks_json = std.ArrayList(u8).empty;
    defer ep_audio_tracks_json.deinit(allocator);

    if (ep.duration_sec > 0.0 and ep.audio_tracks_json != null) {
        ep_duration_sec = ep.duration_sec;
        ep_runtime = @as(u32, @intFromFloat(ep.duration_sec / 60.0));
        try ep_audio_tracks_json.appendSlice(allocator, ep.audio_tracks_json.?);
    } else if (common.resolveMediaPath(database, allocator, .{ .library_id = sh.library_id, .file_path = ep.file_path }) catch null) |resolved| {
        defer allocator.free(resolved.resolved_path);

        if (ep_file_size == 0) {
            if (std.Io.Dir.cwd().statFile(io, resolved.resolved_path, .{}) catch null) |st| {
                ep_file_size = st.size;
            }
        }

        if (allocator.dupeSentinel(u8, resolved.resolved_path, 0) catch null) |cp| {
            defer allocator.free(cp);
            if (streamer.getMediaInfoFast(allocator, io, cp) catch null) |media_info| {
                defer media_info.deinit(allocator);
                if (media_info.duration > 0) {
                    ep_duration_sec = media_info.duration;
                    ep_runtime = @as(u32, @intFromFloat(media_info.duration / 60.0));
                }
                try appendAudioTracksJson(allocator, &ep_audio_tracks_json, media_info.audio_tracks);
                if (ep_duration_sec > 0.0) {
                    cat.cacheEpisodeMediaInfo(ep.id, @intCast(ep_file_size), ep_duration_sec, ep_audio_tracks_json.items) catch {};
                    cat.snapshot() catch {};
                }
            }
        }
    }
    if (ep_audio_tracks_json.items.len == 0) {
        try ep_audio_tracks_json.appendSlice(allocator, "[]");
    }

    const basename = std.fs.path.basename(ep.file_path);
    const display_title = ep.title orelse basename;
    const display_overview = ep.overview orelse "";
    const still_path = ep.still_path orelse "";
    const ep_resume_pos = logging_mod.getEpisodePlaybackProgress(database, session_info.username, ep.id) catch 0.0;

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);
    try json.ensureTotalCapacity(allocator, 512 + display_overview.len + ep_audio_tracks_json.items.len);

    var num_buf: [128]u8 = undefined;
    try json.appendSlice(allocator, try std.fmt.bufPrint(
        &num_buf,
        "{{\"success\":true,\"episode\":{{\"id\":{d},\"show_id\":{d},\"library_id\":{d},\"season\":{d},\"episode\":{d},\"title\":\"",
        .{ ep.id, ep.show_id, sh.library_id, ep.season, ep.episode },
    ));
    try utils.escapeJsonString(&json, allocator, display_title);
    try json.appendSlice(allocator, "\",\"overview\":\"");
    try utils.escapeJsonString(&json, allocator, display_overview);
    try json.appendSlice(allocator, "\",\"still_path\":\"");
    try utils.escapeJsonString(&json, allocator, still_path);
    try json.appendSlice(allocator, try std.fmt.bufPrint(
        &num_buf,
        "\",\"file_size\":{d},\"runtime\":{d},\"duration_sec\":{d:.2},\"resume_position\":{d:.1},\"audio_tracks\":",
        .{ ep_file_size, ep_runtime, ep_duration_sec, ep_resume_pos },
    ));
    try json.appendSlice(allocator, ep_audio_tracks_json.items);
    try json.appendSlice(allocator, "}}");

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
