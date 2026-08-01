const std = @import("std");
const catalog_index = @import("catalog/index.zig");
const catalog_library = @import("catalog/library.zig");
const catalog_details = @import("catalog/details.zig");
const db_mod = @import("../db/db.zig");
const session_mod = @import("../db/session.zig");
const config_mod = @import("../config.zig");

const auth_handler = @import("handlers/auth.zig");
const static_handler = @import("handlers/static.zig");
const player_html = @import("handlers/player/html.zig");
const player_stream = @import("handlers/player/stream.zig");
const player_subtitles = @import("handlers/player/subtitles.zig");
const player_raw = @import("handlers/player/raw.zig");

const admin_router = @import("routers/admin.zig");
const api_router = @import("routers/api.zig");
const catalog_router = @import("routers/catalog.zig");
const api_v1_router = @import("routers/api_v1.zig");

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

        // Route: API v1 Login
        if (std.mem.eql(u8, target, "/api/v1/login")) {
            api_v1_router.handleLogin(&request, allocator, database, logs_database, &resp_buf, io) catch return;
            continue;
        }

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

        // Route: Media Streamer (Public for Cast receivers & media elements)
        if (std.mem.startsWith(u8, target, "/stream?")) {
            var stream_resp_buf: [8192]u8 = undefined;
            player_stream.handleStream(&request, allocator, database, &stream_resp_buf) catch return;
            continue;
        } else if (std.mem.startsWith(u8, target, "/subtitles?")) {
            player_subtitles.handleSubtitles(&request, allocator, database, io) catch |err| {
                std.debug.print("Subtitles handler error: {}\n", .{err});
            };
            continue;
        } else if (std.mem.startsWith(u8, target, "/api/v1/play?")) {
            var stream_resp_buf: [8192]u8 = undefined;
            player_raw.handleRawPlay(&request, allocator, database, &stream_resp_buf, io) catch return;
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

        // Route: API v1 Libraries (Protected)
        if (std.mem.eql(u8, target, "/api/v1/libraries")) {
            api_v1_router.handleGetLibraries(&request, allocator, database) catch return;
            continue;
        }

        // Route: API v1 Library Items (Protected)
        if (std.mem.startsWith(u8, target, "/api/v1/library?")) {
            api_v1_router.handleGetLibraryItems(&request, allocator, database) catch return;
            continue;
        }
        
        // Route: API v1 Movie Details (Protected)
        if (std.mem.startsWith(u8, target, "/api/v1/movie?")) {
            api_v1_router.handleGetMovie(&request, allocator, database) catch return;
            continue;
        }

        // Route: API v1 Show Details (Protected)
        if (std.mem.startsWith(u8, target, "/api/v1/show?")) {
            api_v1_router.handleGetShow(&request, allocator, database) catch return;
            continue;
        }

        // Route: HTML Player
        if (std.mem.startsWith(u8, target, "/player?")) {
            player_html.handlePlayer(&request, allocator, database, logs_database, session_info.?.username, io) catch return;
            continue;
        }

        if (api_router.route(&request, allocator, io, config, database, logs_database, session_info, &resp_buf) catch return) {
            continue;
        }

        if (admin_router.route(&request, allocator, io, database, session_info, &resp_buf) catch return) {
            continue;
        }

        if (catalog_router.route(&request, allocator, io, database, logs_database, session_info) catch return) {
            continue;
        }

        // Unknown route
        request.respond("Not found", .{ .status = .not_found }) catch return;
    }
}
