const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const library_mod = @import("../../../db/library.zig");
const utils = @import("../../utils.zig");

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

        const lib_json = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"name\":\"{s}\",\"type\":\"{s}\"}}", .{ lib.id, escaped_name.items, lib.lib_type.toString() });
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
    const cat = database.catalog orelse {
        try request.respond("{\"success\":false,\"error\":\"Catalog not configured\"}", .{ .status = .internal_server_error });
        return;
    };

    if (lib.lib_type == .Shows) {
        const shows = try cat.getShowsByLibrary(allocator, lib.id);
        defer {
            for (shows) |*s| {
                var mut = s.*;
                mut.deinit(allocator);
            }
            allocator.free(shows);
        }

        for (shows) |s| {
            if (!first) try json.appendSlice(allocator, ",");
            first = false;

            const show_id = s.id;
            const title = s.title;
            const poster_path = s.poster_path orelse "";
            var tmdb_id_buf: [32]u8 = undefined;
            const tmdb_id_str = if (s.tmdb_id) |tid| std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "" else "";

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

            const item_json = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"title\":\"{s}\",\"poster_path\":\"{s}\",\"tmdb_id\":\"{s}\",\"type\":\"show\"}}", .{ show_id, escaped_title.items, poster_path, tmdb_id_str });
            defer allocator.free(item_json);
            try json.appendSlice(allocator, item_json);
        }
    } else {
        const movies = try cat.getMoviesByLibrary(allocator, lib.id);
        defer {
            for (movies) |*m| {
                var mut = m.*;
                mut.deinit(allocator);
            }
            allocator.free(movies);
        }

        for (movies) |m| {
            if (!first) try json.appendSlice(allocator, ",");
            first = false;

            const movie_id = m.id;
            const display_title = m.title orelse m.clean_name;
            const poster_path = m.poster_path orelse "";
            var tmdb_id_buf: [32]u8 = undefined;
            const tmdb_id_str = if (m.tmdb_id) |tid| std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "" else "";

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

            const item_json = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"title\":\"{s}\",\"poster_path\":\"{s}\",\"tmdb_id\":\"{s}\",\"type\":\"movie\"}}", .{ movie_id, escaped_title.items, poster_path, tmdb_id_str });
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

const RenameLibraryPayload = struct {
    library_id: i64,
    name: []const u8,
};

pub fn handleRenameLibrary(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    is_admin: bool,
    body_buf: *[8192]u8,
) !void {
    if (request.head.method != .POST and request.head.method != .PATCH) {
        try request.respond("{\"success\":false,\"error\":\"Method not allowed\"}", .{ .status = .method_not_allowed });
        return;
    }

    if (!is_admin) {
        try request.respond("{\"success\":false,\"error\":\"Forbidden: Admin access required\"}", .{
            .status = .forbidden,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
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

    const parsed = std.json.parseFromSlice(RenameLibraryPayload, allocator, body_data.items, .{
        .ignore_unknown_fields = true,
    }) catch {
        try request.respond("{\"success\":false,\"error\":\"Invalid JSON body\"}", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    };
    defer parsed.deinit();

    const trimmed = std.mem.trim(u8, parsed.value.name, " \t\r\n");
    if (trimmed.len == 0) {
        try request.respond("{\"success\":false,\"error\":\"Library name cannot be empty\"}", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return;
    }

    library_mod.renameLibrary(database, parsed.value.library_id, trimmed) catch |err| switch (err) {
        error.LibraryNotFound => {
            try request.respond("{\"success\":false,\"error\":\"Library not found\"}", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
            return;
        },
        error.EmptyLibraryName => {
            try request.respond("{\"success\":false,\"error\":\"Library name cannot be empty\"}", .{
                .status = .bad_request,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
            return;
        },
        else => {
            try request.respond("{\"success\":false,\"error\":\"Internal Server Error\"}", .{
                .status = .internal_server_error,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
            return;
        },
    };

    var escaped_name = std.ArrayList(u8).empty;
    defer escaped_name.deinit(allocator);
    for (trimmed) |ch| {
        switch (ch) {
            '"' => try escaped_name.appendSlice(allocator, "\\\""),
            '\\' => try escaped_name.appendSlice(allocator, "\\\\"),
            '\n' => try escaped_name.appendSlice(allocator, "\\n"),
            '\r' => try escaped_name.appendSlice(allocator, "\\r"),
            '\t' => try escaped_name.appendSlice(allocator, "\\t"),
            else => try escaped_name.append(allocator, ch),
        }
    }

    const resp_json = try std.fmt.allocPrint(allocator, "{{\"success\":true,\"library\":{{\"id\":{d},\"name\":\"{s}\"}}}}", .{ parsed.value.library_id, escaped_name.items });
    defer allocator.free(resp_json);

    try request.respond(resp_json, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}
