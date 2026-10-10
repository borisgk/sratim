const std = @import("std");
const db_mod = @import("../../db/db.zig");
const library_mod = @import("../../db/library.zig");
const scanner_mod = @import("../../db/scanner.zig");
const browse_handler = @import("browse.zig");
const utils = @import("../utils.zig");

/// Handles POST /libraries/add — validates library config and inserts to DB.
pub fn handleLibraryAdd(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, body_buf: *[8192]u8) !void {
    const body_data = utils.readRequestBody(request, allocator, body_buf) catch {
        request.respond("Error reading request body", .{ .status = .bad_request }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const name_raw = utils.getFormValue(body_data, "name");
    const path_raw = utils.getFormValue(body_data, "path");
    const type_raw = utils.getFormValue(body_data, "type");

    const name: ?[]const u8 = if (name_raw) |n| try utils.urlDecode(allocator, n) else null;
    defer if (name) |n| allocator.free(n);
    const path: ?[]const u8 = if (path_raw) |p| try utils.urlDecode(allocator, p) else null;
    defer if (path) |p| allocator.free(p);
    var type_str: ?[]const u8 = if (type_raw) |t| try utils.urlDecode(allocator, t) else null;
    defer if (type_str) |t| allocator.free(t);
    if (type_str) |t| {
        type_str = std.mem.trim(u8, t, " \r\n");
    }


    std.debug.print("RAW BODY: {s}\n", .{body_data});
    std.debug.print("PARSED: name={?s}, path={?s}, type={?s}\n", .{ name, path, type_str });

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

    const body_data = utils.readRequestBody(request, allocator, body_buf) catch {
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(LibraryRescanPayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse library rescan JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    scanner_mod.scanLibraryById(database, allocator, io, parsed.value.library_id) catch |err| {
        std.debug.print("Failed to rescan library {d}: {}\n", .{ parsed.value.library_id, err });
        request.respond("Error rescanning library.", .{ .status = .internal_server_error }) catch return;
        return;
    };

    request.respond("OK", .{ .status = .ok }) catch return;
}

const LibraryRenamePayload = struct {
    library_id: i64,
    name: []const u8,
};

/// Handles POST /api/library/rename — renames an existing library (admin only).
pub fn handleLibraryRename(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    is_admin: bool,
    body_buf: *[8192]u8,
) !void {
    if (!is_admin) {
        request.respond("Forbidden: Admin access required", .{ .status = .forbidden }) catch return;
        return;
    }

    const body_data = utils.readRequestBody(request, allocator, body_buf) catch {
        request.respond("Bad Request: Invalid body", .{ .status = .bad_request }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(LibraryRenamePayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse library rename JSON: {any}\n", .{err});
        request.respond("Bad Request: Invalid JSON body", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const trimmed_name = std.mem.trim(u8, parsed.value.name, " \t\r\n");
    if (trimmed_name.len == 0) {
        request.respond("Bad Request: Library name cannot be empty", .{ .status = .bad_request }) catch return;
        return;
    }

    library_mod.renameLibrary(database, parsed.value.library_id, trimmed_name) catch |err| switch (err) {
        error.LibraryNotFound => {
            request.respond("Not Found: Library not found", .{ .status = .not_found }) catch return;
            return;
        },
        error.EmptyLibraryName => {
            request.respond("Bad Request: Library name cannot be empty", .{ .status = .bad_request }) catch return;
            return;
        },
        else => {
            std.debug.print("Failed to rename library {d}: {}\n", .{ parsed.value.library_id, err });
            request.respond("Error renaming library.", .{ .status = .internal_server_error }) catch return;
            return;
        },
    };

    request.respond("{\"success\":true}", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return;
}

const LibraryDeletePayload = struct {
    library_id: i64,
};

/// Handles POST /api/library/delete — deletes an existing library without deleting disk content (admin only).
pub fn handleLibraryDelete(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    is_admin: bool,
    body_buf: *[8192]u8,
) !void {
    if (!is_admin) {
        request.respond("Forbidden: Admin access required", .{ .status = .forbidden }) catch return;
        return;
    }

    const body_data = utils.readRequestBody(request, allocator, body_buf) catch {
        request.respond("Bad Request: Invalid body", .{ .status = .bad_request }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(LibraryDeletePayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse library delete JSON: {any}\n", .{err});
        request.respond("Bad Request: Invalid JSON body", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    library_mod.deleteLibrary(database, parsed.value.library_id) catch |err| switch (err) {
        error.LibraryNotFound => {
            request.respond("Not Found: Library not found", .{ .status = .not_found }) catch return;
            return;
        },
        else => {
            std.debug.print("Failed to delete library {d}: {}\n", .{ parsed.value.library_id, err });
            request.respond("Error deleting library.", .{ .status = .internal_server_error }) catch return;
            return;
        },
    };

    request.respond("{\"success\":true}", .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return;
}

/// Handles GET /api/library/updates — returns JSON diff of items and remaining pending count for library.
pub fn handleApiLibraryUpdates(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database) !void {
    const lib_id = utils.parseQueryInt(i64, request.head.target, "id") orelse {
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

    const cat = database.catalog orelse return;
    cat.rwlock.lockSharedUncancelable(cat.io);
    defer cat.rwlock.unlockShared(cat.io);

    var pending_count: i64 = 0;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    if (lib.lib_type == .Shows) {
        var it = cat.shows.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.library_id == lib_id and e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
                pending_count += 1;
            }
        }

        try json.appendSlice(allocator, "{\"remaining_pending\":");
        var count_buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{pending_count});
        try json.appendSlice(allocator, count_str);
        try json.appendSlice(allocator, ",\"updates\":[");

        var first = true;
        var sh_it = cat.shows.iterator();
        while (sh_it.next()) |e| {
            if (e.value_ptr.library_id == lib_id and e.value_ptr.is_present and e.value_ptr.tmdb_id != null and e.value_ptr.tmdb_id.? > 0) {
                const id = e.key_ptr.*;
                const tmdb_id = e.value_ptr.tmdb_id.?;
                const title = e.value_ptr.title;
                const poster_path_opt = e.value_ptr.poster_path;

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
        }
        try json.appendSlice(allocator, "]}");
    } else {
        var it = cat.movies.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.library_id == lib_id and e.value_ptr.is_present and (e.value_ptr.tmdb_id == null or e.value_ptr.tmdb_id.? == 0)) {
                pending_count += 1;
            }
        }

        try json.appendSlice(allocator, "{\"remaining_pending\":");
        var count_buf: [32]u8 = undefined;
        const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{pending_count});
        try json.appendSlice(allocator, count_str);
        try json.appendSlice(allocator, ",\"updates\":[");

        var first = true;
        var m_it = cat.movies.iterator();
        while (m_it.next()) |e| {
            if (e.value_ptr.library_id == lib_id and e.value_ptr.is_present and e.value_ptr.tmdb_id != null and e.value_ptr.tmdb_id.? > 0) {
                const id = e.key_ptr.*;
                const tmdb_id = e.value_ptr.tmdb_id.?;
                const title = e.value_ptr.title orelse e.value_ptr.clean_name;
                const poster_path_opt = e.value_ptr.poster_path;

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
