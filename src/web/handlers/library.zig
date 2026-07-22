const std = @import("std");
const db_mod = @import("../../db/db.zig");
const library_mod = @import("../../db/library.zig");
const player_handler = @import("player.zig");
const browse_handler = @import("browse.zig");

/// Handles POST /libraries/add — validates library config and inserts to DB.
pub fn handleLibraryAdd(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, body_buf: *[8192]u8) !void {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    var name: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var type_str: ?[]const u8 = null;

    var pairs = std.mem.splitScalar(u8, body_data.items, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "name=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            std.mem.replaceScalar(u8, decoded, '+', ' ');
            name = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "path=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            std.mem.replaceScalar(u8, decoded, '+', ' ');
            path = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "type=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            std.mem.replaceScalar(u8, decoded, '+', ' ');
            type_str = std.Uri.percentDecodeInPlace(decoded);
            if (type_str) |t| {
                type_str = std.mem.trim(u8, t, " \r\n");
            }
        }
    }

    std.debug.print("RAW BODY: {s}\n", .{body_data.items});
    std.debug.print("PARSED: name={?s}, path={?s}, type={?s}\n", .{name, path, type_str});

    if (name != null and path != null and type_str != null) {
        const lib_type = library_mod.LibraryType.fromString(type_str.?) orelse .Other;
        library_mod.addLibrary(database, name.?, path.?, lib_type) catch |err| {
            std.debug.print("Failed to add library: {}\n", .{err});
            request.respond("Error adding library folder.", .{ .status = .internal_server_error }) catch return;
            return;
        };

        request.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "location", .value = "/" },
            },
        }) catch return;
    } else {
        request.respond("Missing name, path or type", .{ .status = .bad_request }) catch return;
    }
}

const LibraryRescanPayload = struct {
    library_id: i64,
};

/// Handles POST /api/library/rescan — triggers scanning for a specific library (admin only).
pub fn handleLibraryRescan(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, is_admin: bool, body_buf: *[8192]u8) !void {
    if (!is_admin) {
        request.respond("Forbidden", .{ .status = .forbidden }) catch return;
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

    const parsed = std.json.parseFromSlice(LibraryRescanPayload, allocator, body_data.items, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse library rescan JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    library_mod.scanLibraryById(database, allocator, io, parsed.value.library_id) catch |err| {
        std.debug.print("Failed to rescan library {d}: {}\n", .{ parsed.value.library_id, err });
        request.respond("Error rescanning library.", .{ .status = .internal_server_error }) catch return;
        return;
    };

    request.respond("OK", .{ .status = .ok }) catch return;
}

/// Handles GET /api/library/updates — returns JSON diff of items and remaining pending count for library.
pub fn handleApiLibraryUpdates(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database) !void {
    const lib_id = player_handler.parseQueryInt(i64, request.head.target, "id") orelse {
        request.respond("Missing library id", .{ .status = .bad_request }) catch return;
        return;
    };

    const lib_opt = try library_mod.getLibraryById(database, allocator, lib_id);
    if (lib_opt == null) {
        request.respond("Library not found", .{ .status = .not_found }) catch return;
        return;
    }
    const lib = lib_opt.?;
    defer {
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    var pending_count: i64 = 0;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    if (lib.lib_type == .Shows) {
        var count_stmt = try database.prepare("SELECT COUNT(*) FROM shows WHERE library_id = ?1 AND is_present = 1 AND tmdb_id IS NULL;");
        defer count_stmt.finalize();
        try count_stmt.bindInt64(1, lib_id);
        if ((try count_stmt.step()) == .row) {
            pending_count = count_stmt.columnInt64(0);
        }

        var stmt = try database.prepare("SELECT id, tmdb_id, title, poster_path FROM shows WHERE library_id = ?1 AND is_present = 1 AND tmdb_id IS NOT NULL;");
        defer stmt.finalize();
        try stmt.bindInt64(1, lib_id);

        try json.appendSlice(allocator, "{\"remaining_pending\":");
        var count_buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{pending_count});
        try json.appendSlice(allocator, count_str);
        try json.appendSlice(allocator, ",\"updates\":[");

        var first = true;
        while ((try stmt.step()) == .row) {
            const id = stmt.columnInt64(0);
            const tmdb_id = stmt.columnInt64(1);
            const title = stmt.columnText(2) orelse "";
            const poster_path_opt = stmt.columnText(3);

            if (!first) try json.appendSlice(allocator, ",");
            first = false;

            const item_buf = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"tmdb_id\":{d},\"title\":\"", .{ id, tmdb_id });
            defer allocator.free(item_buf);
            try json.appendSlice(allocator, item_buf);
            try browse_handler.escapeJsonString(&json, allocator, title);
            try json.appendSlice(allocator, "\",\"poster_path\":");

            if (poster_path_opt) |p| {
                try json.appendSlice(allocator, "\"");
                try browse_handler.escapeJsonString(&json, allocator, p);
                try json.appendSlice(allocator, "\"");
            } else {
                try json.appendSlice(allocator, "null");
            }
            try json.appendSlice(allocator, "}");
        }
        try json.appendSlice(allocator, "]}");
    } else {
        var count_stmt = try database.prepare("SELECT COUNT(*) FROM movies WHERE library_id = ?1 AND is_present = 1 AND tmdb_id IS NULL;");
        defer count_stmt.finalize();
        try count_stmt.bindInt64(1, lib_id);
        if ((try count_stmt.step()) == .row) {
            pending_count = count_stmt.columnInt64(0);
        }

        var stmt = try database.prepare("SELECT id, tmdb_id, COALESCE(title, clean_name), poster_path FROM movies WHERE library_id = ?1 AND is_present = 1 AND tmdb_id IS NOT NULL;");
        defer stmt.finalize();
        try stmt.bindInt64(1, lib_id);

        try json.appendSlice(allocator, "{\"remaining_pending\":");
        var count_buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{pending_count});
        try json.appendSlice(allocator, count_str);
        try json.appendSlice(allocator, ",\"updates\":[");

        var first = true;
        while ((try stmt.step()) == .row) {
            const id = stmt.columnInt64(0);
            const tmdb_id = stmt.columnInt64(1);
            const title = stmt.columnText(2) orelse "";
            const poster_path_opt = stmt.columnText(3);

            if (!first) try json.appendSlice(allocator, ",");
            first = false;

            const item_buf = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"tmdb_id\":{d},\"title\":\"", .{ id, tmdb_id });
            defer allocator.free(item_buf);
            try json.appendSlice(allocator, item_buf);
            try browse_handler.escapeJsonString(&json, allocator, title);
            try json.appendSlice(allocator, "\",\"poster_path\":");

            if (poster_path_opt) |p| {
                try json.appendSlice(allocator, "\"");
                try browse_handler.escapeJsonString(&json, allocator, p);
                try json.appendSlice(allocator, "\"");
            } else {
                try json.appendSlice(allocator, "null");
            }
            try json.appendSlice(allocator, "}");
        }
        try json.appendSlice(allocator, "]}");
    }

    request.respond(json.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return;
}
