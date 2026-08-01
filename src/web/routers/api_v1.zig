const std = @import("std");
const db_mod = @import("../../db/db.zig");
const users_mod = @import("../../db/users.zig");
const logging_mod = @import("../../db/logging.zig");
const session_mod = @import("../../db/session.zig");
const library_mod = @import("../../db/library.zig");
const utils = @import("../utils.zig");

const LoginPayload = struct {
    username: []const u8,
    password: []const u8,
};

pub fn handleLogin(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    body_buf: *[8192]u8,
    io: std.Io,
) !void {
    var client_ip: []const u8 = "127.0.0.1";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for") or std.ascii.eqlIgnoreCase(header.name, "x-real-ip")) {
            client_ip = header.value;
            break;
        }
    }

    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    if (request.head.method != .POST) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    const parsed = std.json.parseFromSlice(LoginPayload, allocator, body_data.items, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse login JSON: {any}\n", .{err});
        try request.respond("{\"success\":false,\"error\":\"Bad request\"}", .{ .status = .bad_request });
        return;
    };
    defer parsed.deinit();

    const username = parsed.value.username;
    const password = parsed.value.password;

    const valid = users_mod.verifyPassword(database, allocator, username, password) catch false;
    if (!valid) {
        logging_mod.logLoginAttempt(logs_database, username, "failed", client_ip) catch |err| {
            std.debug.print("Failed to log failed auth attempt: {}\n", .{err});
        };
        try request.respond("{\"success\":false,\"error\":\"Invalid credentials\"}", .{ .status = .unauthorized });
        return;
    }

    const is_admin = users_mod.isAdmin(database, username) catch false;

    logging_mod.logLoginAttempt(logs_database, username, "success", client_ip) catch |err| {
        std.debug.print("Failed to log successful auth attempt: {}\n", .{err});
    };

    const token = try session_mod.createSession(database, allocator, io, username, is_admin);

    const is_admin_str = if (is_admin) "true" else "false";
    const resp_json = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"token\":\"{s}\",\"is_admin\":{s}}}", .{ token, is_admin_str });
    defer allocator.free(resp_json);

    try request.respond(resp_json, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

pub fn handleGetLibraries(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
) !void {
    if (request.head.method != .GET) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    const libraries = library_mod.getLibraries(database, allocator) catch |err| {
        std.debug.print("Error getting libraries: {}\n", .{err});
        try request.respond("{\"success\":false,\"error\":\"Internal Server Error\"}", .{ .status = .internal_server_error });
        return;
    };
    defer {
        for (libraries) |lib| {
            allocator.free(lib.name);
            allocator.free(lib.path);
            allocator.free(lib.metadata_language);
            if (lib.ignore_patterns) |pat| allocator.free(pat);
        }
        allocator.free(libraries);
    }

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"success\":true,\"libraries\":[");
    for (libraries, 0..) |lib, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        
        var escaped_name = std.ArrayList(u8).empty;
        defer escaped_name.deinit(allocator);
        for (lib.name) |c| {
            switch (c) {
                '"' => try escaped_name.appendSlice(allocator, "\\\""),
                '\\' => try escaped_name.appendSlice(allocator, "\\\\"),
                '\n' => try escaped_name.appendSlice(allocator, "\\n"),
                '\r' => try escaped_name.appendSlice(allocator, "\\r"),
                '\t' => try escaped_name.appendSlice(allocator, "\\t"),
                else => try escaped_name.append(allocator, c),
            }
        }

        const lib_json = try std.fmt.allocPrint(allocator, 
            "{{\"id\":{d},\"name\":\"{s}\",\"type\":\"{s}\"}}",
            .{ lib.id, escaped_name.items, lib.lib_type.toString() }
        );
        defer allocator.free(lib_json);
        try json.appendSlice(allocator, lib_json);
    }
    try json.appendSlice(allocator, "]}");

    try request.respond(json.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

pub fn handleGetLibraryItems(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
) !void {
    if (request.head.method != .GET) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    const lib_id = utils.parseQueryInt(i64, request.head.target, "id") orelse {
        try request.respond("{\"success\":false,\"error\":\"Missing library id\"}", .{ .status = .bad_request });
        return;
    };

    const lib_opt = try library_mod.getLibraryById(database, allocator, lib_id);
    if (lib_opt == null) {
        try request.respond("{\"success\":false,\"error\":\"Library not found\"}", .{ .status = .not_found });
        return;
    }
    const lib = lib_opt.?;
    defer {
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"success\":true,\"items\":[");

    var first = true;
    if (lib.lib_type == .Shows) {
        var stmt = try database.prepare(
            \\SELECT id, title, poster_path, tmdb_id 
            \\FROM shows
            \\WHERE library_id = ?1 AND is_present = 1
            \\ORDER BY 
            \\    CASE 
            \\        WHEN title LIKE 'The %' THEN SUBSTR(title, 5)
            \\        WHEN title LIKE 'A %' THEN SUBSTR(title, 3)
            \\        WHEN title LIKE 'An %' THEN SUBSTR(title, 4)
            \\        ELSE title
            \\    END COLLATE NOCASE ASC;
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, lib.id);

        while ((try stmt.step()) == .row) {
            if (!first) try json.appendSlice(allocator, ",");
            first = false;

            const show_id = stmt.columnInt64(0);
            const title = stmt.columnText(1).?;
            const poster_path_opt = stmt.columnText(2);
            const poster_path = if (poster_path_opt != null) poster_path_opt.? else "";
            const tmdb_id_str = stmt.columnText(3) orelse "";

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

            const item_json = try std.fmt.allocPrint(allocator, 
                "{{\"id\":{d},\"title\":\"{s}\",\"poster_path\":\"{s}\",\"tmdb_id\":\"{s}\",\"type\":\"show\"}}",
                .{ show_id, escaped_title.items, poster_path, tmdb_id_str }
            );
            defer allocator.free(item_json);
            try json.appendSlice(allocator, item_json);
        }
    } else {
        var stmt = try database.prepare(
            \\SELECT id, file_path, clean_name, title, poster_path, tmdb_id 
            \\FROM movies
            \\WHERE library_id = ?1 AND is_present = 1
            \\ORDER BY 
            \\    CASE 
            \\        WHEN COALESCE(title, clean_name) LIKE 'The %' THEN SUBSTR(COALESCE(title, clean_name), 5)
            \\        WHEN COALESCE(title, clean_name) LIKE 'A %' THEN SUBSTR(COALESCE(title, clean_name), 3)
            \\        WHEN COALESCE(title, clean_name) LIKE 'An %' THEN SUBSTR(COALESCE(title, clean_name), 4)
            \\        ELSE COALESCE(title, clean_name)
            \\    END COLLATE NOCASE ASC;
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, lib.id);

        while ((try stmt.step()) == .row) {
            if (!first) try json.appendSlice(allocator, ",");
            first = false;

            const movie_id = stmt.columnInt64(0);
            const clean_name = stmt.columnText(2).?;
            const title_opt = stmt.columnText(3);
            const poster_path_opt = stmt.columnText(4);
            const tmdb_id_str = stmt.columnText(5) orelse "";
            
            const display_title = if (title_opt) |t| t else clean_name;
            const poster_path = if (poster_path_opt != null) poster_path_opt.? else "";

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

            const item_json = try std.fmt.allocPrint(allocator, 
                "{{\"id\":{d},\"title\":\"{s}\",\"poster_path\":\"{s}\",\"tmdb_id\":\"{s}\",\"type\":\"movie\"}}",
                .{ movie_id, escaped_title.items, poster_path, tmdb_id_str }
            );
            defer allocator.free(item_json);
            try json.appendSlice(allocator, item_json);
        }
    }

    try json.appendSlice(allocator, "]}");

    try request.respond(json.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

pub fn handleGetMovie(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
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
        const file_path = stmt.columnText(2) orelse "";
        const clean_name = stmt.columnText(3) orelse "";
        const title_opt = stmt.columnText(4);
        const overview = stmt.columnText(5) orelse "";
        const poster_path = stmt.columnText(6) orelse "";
        const backdrop_path = stmt.columnText(7) orelse "";
        const release_date = stmt.columnText(8) orelse "";
        const tmdb_id = stmt.columnText(9) orelse "";
        const file_size = stmt.columnInt64(10);
        
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
            "{{\"success\":true,\"movie\":{{\"id\":{d},\"library_id\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"poster_path\":\"{s}\",\"backdrop_path\":\"{s}\",\"release_date\":\"{s}\",\"tmdb_id\":\"{s}\",\"file_size\":{d},\"file_path\":\"{s}\"}}}}",
            .{ id, library_id, escaped_title.items, escaped_overview.items, poster_path, backdrop_path, release_date, tmdb_id, file_size, file_path }
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
        \\SELECT id, file_path, season, episode, title, overview, still_path
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
            "{{\"id\":{d},\"season\":{d},\"episode\":{d},\"title\":\"{s}\",\"overview\":\"{s}\",\"still_path\":\"{s}\"}}",
            .{ ep_id, season, episode, esc_ep_title.items, esc_ep_overview.items, still_path }
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
