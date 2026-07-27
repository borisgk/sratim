const std = @import("std");
const db_mod = @import("../../db/db.zig");
const session_mod = @import("../../db/session.zig");
const config_mod = @import("../../config.zig");

const library_handler = @import("../handlers/library.zig");
const browse_handler = @import("../handlers/browse.zig");
const watch_handler = @import("../handlers/watch.zig");
const metadata_handler = @import("../handlers/metadata.zig");

pub fn route(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    session_info_opt: ?session_mod.SessionInfo,
    resp_buf: *[8192]u8,
) !bool {
    const target = request.head.target;
    const method = request.head.method;

    if (!std.mem.startsWith(u8, target, "/api/") and !std.mem.startsWith(u8, target, "/libraries/add")) {
        return false;
    }

    if (session_info_opt == null) {
        try request.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "location", .value = "/login" },
            },
        });
        return true;
    }

    const session_info = session_info_opt.?;

    if (std.mem.startsWith(u8, target, "/libraries/add") and method == .POST) {
        if (!session_info.is_admin) {
            try request.respond("403 Forbidden: Admin access required", .{ .status = .forbidden });
            return true;
        }
        try library_handler.handleLibraryAdd(request, allocator, database, resp_buf);
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/library/rescan") and method == .POST) {
        library_handler.handleLibraryRescan(request, allocator, io, database, session_info.is_admin, resp_buf) catch |err| {
            std.debug.print("API Library Rescan error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/library/updates") and method == .GET) {
        library_handler.handleApiLibraryUpdates(request, allocator, database) catch |err| {
            std.debug.print("API Library Updates error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/browse")) {
        if (!session_info.is_admin) {
            try request.respond("403 Forbidden: Admin access required", .{ .status = .forbidden });
            return true;
        }
        browse_handler.handleApiBrowse(request, allocator, io) catch |err| {
            std.debug.print("API Browse error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/watch/event") and method == .POST) {
        watch_handler.handleApiWatchEvent(request, allocator, logs_database, session_info.username, resp_buf) catch |err| {
            std.debug.print("API Watch Event error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/metadata/search") and method == .GET) {
        if (!session_info.is_admin) {
            try request.respond("403 Forbidden: Admin access required", .{ .status = .forbidden });
            return true;
        }
        metadata_handler.handleApiMetadataSearch(request, allocator, io, config) catch |err| {
            std.debug.print("API Metadata Search error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/metadata/link") and method == .POST) {
        if (!session_info.is_admin) {
            try request.respond("403 Forbidden: Admin access required", .{ .status = .forbidden });
            return true;
        }
        metadata_handler.handleApiMetadataLink(request, allocator, io, database, config, resp_buf) catch |err| {
            std.debug.print("API Metadata Link error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/metadata/auto-link") and method == .POST) {
        if (!session_info.is_admin) {
            try request.respond("403 Forbidden: Admin access required", .{ .status = .forbidden });
            return true;
        }
        metadata_handler.handleApiMetadataAutoLink(request, allocator, io, database, config, resp_buf) catch |err| {
            std.debug.print("API Metadata Auto Link error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    if (std.mem.startsWith(u8, target, "/api/metadata/manual-link") and method == .POST) {
        if (!session_info.is_admin) {
            try request.respond("403 Forbidden: Admin access required", .{ .status = .forbidden });
            return true;
        }
        metadata_handler.handleApiMetadataManualLink(request, allocator, io, database, config, resp_buf) catch |err| {
            std.debug.print("API Metadata Manual Link error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    return false;
}
