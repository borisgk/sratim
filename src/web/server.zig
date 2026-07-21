const std = @import("std");
const catalog = @import("catalog.zig");
const db_mod = @import("../db/db.zig");
const session_mod = @import("../db/session.zig");
const config_mod = @import("../config.zig");

const auth_handler = @import("handlers/auth.zig");
const library_handler = @import("handlers/library.zig");
const browse_handler = @import("handlers/browse.zig");
const watch_handler = @import("handlers/watch.zig");
const metadata_handler = @import("handlers/metadata.zig");
const show_handler = @import("handlers/show.zig");
const static_handler = @import("handlers/static.zig");
const player_handler = @import("handlers/player.zig");

/// Handles an incoming HTTP connection from a client.
/// This function runs inside an isolated OS thread spawned specifically for this connection.
/// It parses headers, routes endpoints, and serves content synchronously.
pub fn handleConnection(stream: std.Io.net.Stream, io: std.Io, config: *const config_mod.Config, database_shared: *db_mod.Database, logs_database_shared: *db_mod.Database) void {
    _ = database_shared;
    _ = logs_database_shared;

    var database_val = db_mod.Database.open("sratim.db") catch |err| {
        std.debug.print("Failed to open database in thread: {}\n", .{err});
        return;
    };
    defer database_val.close();
    const database = &database_val;

    var logs_database_val = db_mod.Database.open("logs.db") catch |err| {
        std.debug.print("Failed to open logs database in thread: {}\n", .{err});
        return;
    };
    defer logs_database_val.close();
    const logs_database = &logs_database_val;

    const working_folder = config.working_folder;
    defer stream.socket.close(io);

    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var buf: [8192]u8 = undefined;
    var out_buf: [8192]u8 = undefined;
    var resp_buf: [8192]u8 = undefined;
    var in = stream.reader(io, &buf);
    var out = stream.writer(io, &out_buf);

    var httpserver = std.http.Server.init(&in.interface, &out.interface);

    while (true) {
        var request = httpserver.receiveHead() catch |err| {
            if (err == error.HttpConnectionClosing or err == error.ConnectionResetByPeer) return;
            return;
        };

        const target = request.head.target;
        const method = request.head.method;

        // --- Public routes (no auth required) ---

        // Route: Login Page
        if (std.mem.startsWith(u8, target, "/login")) {
            if (method == .POST) {
                auth_handler.handleLoginPost(&request, allocator, database, logs_database, &resp_buf, io) catch return;
            } else {
                auth_handler.serveLoginPage(&request, allocator, "") catch return;
            }
            continue;
        }

        // Route: Logout
        if (std.mem.eql(u8, target, "/logout")) {
            auth_handler.handleLogout(&request, allocator, database) catch return;
            continue;
        }

        // Static assets handler (/style.css, /favicon.ico, /fonts/*, /images/*)
        const served_static = static_handler.serveStaticAsset(&request, allocator, io) catch |err| {
            std.debug.print("Static asset error: {}\n", .{err});
            return;
        };
        if (served_static) continue;

        // --- Auth middleware: all remaining routes require a valid session ---
        const session_token = auth_handler.extractCookieToken(&request);
        const session_info = if (session_token) |token|
            session_mod.getSession(database, allocator, token) catch null
        else
            null;

        if (session_info == null) {
            request.respond("", .{
                .status = .found,
                .extra_headers = &.{
                    .{ .name = "location", .value = "/login" },
                },
            }) catch return;
            continue;
        }

        // Route: Catalog (Libraries Home Page)
        if (std.mem.eql(u8, target, "/")) {
            const html_content = catalog.generateHtml(allocator, database) catch |err| {
                std.debug.print("Catalog error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            
            request.respond(html_content, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                },
            }) catch return;

        // Route: Add Library
        } else if (std.mem.startsWith(u8, target, "/libraries/add") and method == .POST) {
            library_handler.handleLibraryAdd(&request, allocator, database, &resp_buf) catch return;
            continue;

        // Route: API Filesystem Browser
        } else if (std.mem.startsWith(u8, target, "/api/browse")) {
            browse_handler.handleApiBrowse(&request, allocator, io) catch |err| {
                std.debug.print("API Browse error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Playback Log / Progress Event
        } else if (std.mem.startsWith(u8, target, "/api/watch/event") and method == .POST) {
            watch_handler.handleApiWatchEvent(&request, allocator, logs_database, session_info.?.username, &resp_buf) catch |err| {
                std.debug.print("API Watch Event error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Playback Progress Modification (reset/watched)
        } else if (std.mem.startsWith(u8, target, "/api/watch/progress/update") and method == .POST) {
            watch_handler.handleApiWatchProgressUpdate(&request, allocator, database, logs_database, session_info.?.username, working_folder, &resp_buf) catch |err| {
                std.debug.print("API Watch Progress Update error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Metadata Link
        } else if (std.mem.startsWith(u8, target, "/api/metadata/link") and method == .POST) {
            metadata_handler.handleApiMetadataLink(&request, allocator, io, database, config, &resp_buf) catch |err| {
                std.debug.print("API Metadata Link error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: Browse Specific Library
        } else if (std.mem.startsWith(u8, target, "/library")) {
            const lib_id = player_handler.parseQueryInt(i64, target, "id") orelse {
                request.respond("Missing library id", .{ .status = .bad_request }) catch return;
                continue;
            };

            const html_content_opt = catalog.generateLibraryContentHtml(allocator, io, database, logs_database, lib_id, session_info.?.username) catch |err| {
                std.debug.print("Browse Library content error: {}\n", .{err});
                if (err == error.LibraryPathNotFound) {
                    request.respond("Library path not found or inaccessible.", .{ .status = .not_found }) catch return;
                } else {
                    request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                }
                continue;
            };

            if (html_content_opt) |html_content| {
                request.respond(html_content, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                    },
                }) catch return;
            } else {
                request.respond("Library not found", .{ .status = .not_found }) catch return;
            }

        // Route: Show Details View
        } else if (std.mem.startsWith(u8, target, "/show")) {
            const show_id = player_handler.parseQueryInt(i64, target, "id") orelse {
                request.respond("Missing show id", .{ .status = .bad_request }) catch return;
                continue;
            };

            show_handler.handleShow(allocator, &request, database, logs_database, session_info.?.username, show_id) catch |err| {
                std.debug.print("Show view error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                continue;
            };

        // Route: Web UI (Player)
        } else if (std.mem.startsWith(u8, target, "/player")) {
            player_handler.handlePlayer(&request, allocator, database, logs_database, session_info.?.username, working_folder) catch |err| {
                std.debug.print("Player handler error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
            };

        // Route: Media Streamer
        } else if (std.mem.startsWith(u8, target, "/stream")) {
            player_handler.handleStream(&request, allocator, database, working_folder, &resp_buf) catch |err| {
                std.debug.print("Stream handler error: {}\n", .{err});
            };
        } else {
            request.respond("Not found", .{ .status = .not_found }) catch return;
        }
    }
}
