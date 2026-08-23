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

    var stmt = try database.prepare(
        \\SELECT id, library_id, file_path, clean_name, title, overview, poster_path, backdrop_path, release_date, tmdb_id, file_size
        \\FROM movies
        \\WHERE id = ?1 AND is_present = 1;
    );
    defer stmt.finalize();
    try stmt.bindInt64(1, movie_id);

    if ((try stmt.step()) == .row) {
        const id = stmt.columnInt64(0);
        const library_id = stmt.columnInt64(1);
        const file_path = stmt.columnText(2).?;
        const clean_name = stmt.columnText(3).?;
        const title_opt = stmt.columnText(4);
        const overview = stmt.columnText(5) orelse "";
        const poster_path = stmt.columnText(6) orelse "";
        const backdrop_path = stmt.columnText(7) orelse "";
        const release_date = stmt.columnText(8) orelse "";
        const tmdb_id = stmt.columnText(9) orelse "";

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
    } else {
        try request.respond("{\"success\":false,\"error\":\"Movie not found\"}", .{ .status = .not_found });
    }
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

    var stmt = try database.prepare("SELECT title, overview, poster_path, backdrop_path, library_id, tmdb_id FROM shows WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt64(1, show_id);

    if ((try stmt.step()) != .row) {
        try request.respond("{\"success\":false,\"error\":\"Show not found\"}", .{ .status = .not_found });
        return;
    }

    const title = stmt.columnText(0).?;
    const overview = stmt.columnText(1) orelse "";
    const poster_path = stmt.columnText(2) orelse "";
    const backdrop_path = stmt.columnText(3) orelse "";
    const library_id = stmt.columnInt64(4);
    const tmdb_id = stmt.columnText(5) orelse "";

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

    var ep_stmt = try database.prepare(
        \\SELECT id, file_path, season, episode, title, overview, still_path, file_size
        \\FROM episodes 
        \\WHERE show_id = ?1 AND is_present = 1
        \\ORDER BY season ASC, episode ASC;
    );
    defer ep_stmt.finalize();
    try ep_stmt.bindInt64(1, show_id);

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
    while ((try ep_stmt.step()) == .row) {
        if (!first_ep) try json.appendSlice(allocator, ",");
        first_ep = false;

        const ep_id = ep_stmt.columnInt64(0);
        const file_path = ep_stmt.columnText(1).?;
        const season = ep_stmt.columnInt(2);
        const episode = ep_stmt.columnInt(3);
        const ep_title_opt = ep_stmt.columnText(4);
        const ep_overview_opt = ep_stmt.columnText(5);
        const ep_still_path_opt = ep_stmt.columnText(6);
        const ep_db_file_size = ep_stmt.columnInt64(7);

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
