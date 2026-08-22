const std = @import("std");
const db_mod = @import("../../db/db.zig");
const session_mod = @import("../../db/session.zig");
const utils = @import("../utils.zig");

const catalog_index = @import("../catalog/index.zig");
const catalog_library = @import("../catalog/library.zig");
const catalog_details = @import("../catalog/details.zig");
const show_handler = @import("../handlers/show.zig");

pub fn route(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    session_info_opt: ?session_mod.SessionInfo,
) !bool {
    const target = request.head.target;

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

    if (std.mem.eql(u8, target, "/")) {
        const html_content = catalog_index.generateHtml(allocator, database, logs_database, session_info.username, session_info.is_admin) catch |err| {
            std.debug.print("Catalog error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
            return true;
        };
        
        try request.respond(html_content, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
        return true;
    }

    if (std.mem.startsWith(u8, target, "/library")) {
        const lib_id = utils.parseQueryInt(i64, target, "id") orelse {
            try request.respond("Missing library id", .{ .status = .bad_request });
            return true;
        };

        const html_content_opt = catalog_library.generateLibraryContentHtml(allocator, io, database, logs_database, lib_id, session_info.username, session_info.is_admin) catch |err| {
            std.debug.print("Browse Library content error: {}\n", .{err});
            if (err == error.LibraryPathNotFound) {
                try request.respond("Library path not found or inaccessible.", .{ .status = .not_found });
            } else {
                try request.respond("Internal Server Error", .{ .status = .internal_server_error });
            }
            return true;
        };

        if (html_content_opt) |html_content| {
            try request.respond(html_content, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                },
            });
        } else {
            try request.respond("Library not found", .{ .status = .not_found });
        }
        return true;
    }

    if (std.mem.startsWith(u8, target, "/details")) {
        const movie_id = utils.parseQueryInt(i64, target, "id") orelse {
            try request.respond("Missing movie id", .{ .status = .bad_request });
            return true;
        };

        const html_content = catalog_details.generateDetailsHtml(allocator, database, logs_database, movie_id, session_info.username) catch |err| {
            std.debug.print("Details view error: {}\n", .{err});
            if (err == error.MovieNotFound) {
                try request.respond("Movie not found", .{ .status = .not_found });
            } else {
                try request.respond("Internal Server Error", .{ .status = .internal_server_error });
            }
            return true;
        };

        try request.respond(html_content, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
        return true;
    }

    if (std.mem.startsWith(u8, target, "/show")) {
        const show_id = utils.parseQueryInt(i64, target, "id") orelse {
            try request.respond("Missing show id", .{ .status = .bad_request });
            return true;
        };

        show_handler.handleShow(allocator, request, database, logs_database, session_info.username, show_id) catch |err| {
            std.debug.print("Show view error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        };
        return true;
    }

    return false;
}
