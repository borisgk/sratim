const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const common = @import("../player/common.zig");
const streamer = @import("../../../media/streamer.zig");
const config_mod = @import("../../../config.zig");
const utils = @import("../../utils.zig");

pub fn handleGetMovie(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    io: std.Io,
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

        if (common.resolveMediaPath(database, allocator, .{ .library_id = library_id, .file_path = file_path }) catch null) |resolved| {
            defer allocator.free(resolved.resolved_path);
            const file = std.Io.Dir.cwd().openFile(io, resolved.resolved_path, .{ .mode = .read_only }) catch null;
            if (file) |f| {
                defer f.close(io);
                if (f.stat(io) catch null) |st| {
                    file_size = st.size;
                }
            }

            const c_path = allocator.dupeZ(u8, resolved.resolved_path) catch null;
            if (c_path) |cp| {
                defer allocator.free(cp);
                if (streamer.getMediaInfo(allocator, io, cp, config.media_engine.metadata) catch null) |media_info| {
                    defer media_info.deinit(allocator);
                    if (media_info.duration > 0) {
                        runtime = @as(u32, @intFromFloat(media_info.duration / 60.0));
                    }
                }
            }
        }

        const display_title = if (title_opt) |t| t else clean_name;

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

        const json = try std.fmt.allocPrint(allocator, 
            "{{\"success\":true,\"movie\":{{\"id\":{d},\"library_id\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"poster_path\":\"{s}\",\"backdrop_path\":\"{s}\",\"release_date\":\"{s}\",\"tmdb_id\":\"{s}\",\"file_size\":{d},\"file_path\":\"{s}\",\"runtime\":{d}}}}}",
            .{ id, library_id, escaped_title.items, escaped_overview.items, poster_path, backdrop_path, release_date, tmdb_id, file_size, file_path, runtime }
        );
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
    const show_header = try std.fmt.allocPrint(allocator, 
        "\"id\":{d},\"library_id\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"poster_path\":\"{s}\",\"backdrop_path\":\"{s}\",\"tmdb_id\":\"{s}\",\"episodes\":[",
        .{ show_id, library_id, escaped_title.items, escaped_overview.items, poster_path, backdrop_path, tmdb_id }
    );
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

        if (common.resolveMediaPath(database, allocator, .{ .library_id = library_id, .file_path = file_path }) catch null) |resolved| {
            defer allocator.free(resolved.resolved_path);

            if (std.Io.Dir.cwd().openFile(io, resolved.resolved_path, .{ .mode = .read_only }) catch null) |file| {
                defer file.close(io);
                if (file.stat(io) catch null) |st| {
                    ep_file_size = st.size;
                }
            }

            const c_path = allocator.dupeZ(u8, resolved.resolved_path) catch null;
            if (c_path) |cp| {
                defer allocator.free(cp);
                if (streamer.getMediaInfo(allocator, io, cp, config.media_engine.metadata) catch null) |media_info| {
                    defer media_info.deinit(allocator);
                    if (media_info.duration > 0) {
                        ep_runtime = @as(u32, @intFromFloat(media_info.duration / 60.0));
                    }
                }
            }
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

        const ep_json = try std.fmt.allocPrint(allocator,
            "{{\"id\":{d},\"season\":{d},\"episode\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"still_path\":\"{s}\",\"file_size\":{d},\"runtime\":{d}}}",
            .{ ep_id, season, episode, esc_ep_title.items, esc_ep_overview.items, still_path, ep_file_size, ep_runtime }
        );
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
