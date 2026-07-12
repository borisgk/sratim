const std = @import("std");
const html = @import("html.zig");
const streamer = @import("streamer.zig");
const catalog = @import("catalog.zig");
const db_mod = @import("db.zig");
const users_mod = @import("users.zig");
const session_mod = @import("session.zig");
const template_engine = @import("template.zig");
const library_mod = @import("library.zig");

/// Handles an incoming HTTP connection from a client.
/// This function runs inside an isolated OS thread spawned specifically for this connection.
/// It parses headers, routes endpoints, and serves content synchronously.
pub fn handleConnection(stream: std.Io.net.Stream, io: std.Io, working_folder: []const u8, database: *db_mod.Database) void {
    // Ensure the socket is always closed when this function exits, no matter what happens
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

    // Keep the connection alive for multiple requests if the client supports Keep-Alive
    while (true) {
        var request = httpserver.receiveHead() catch |err| {
            // Drop connection quietly if the client disconnects or socket breaks
            if (err == error.HttpConnectionClosing or err == error.ConnectionResetByPeer) return;
            return;
        };

        const target = request.head.target;
        const method = request.head.method;

        // --- Public routes (no auth required) ---

        // Route: Login Page
        if (std.mem.startsWith(u8, target, "/login")) {
            if (method == .POST) {
                handleLoginPost(&request, allocator, database, &resp_buf, io) catch return;
            } else {
                serveLoginPage(&request, allocator, "") catch return;
            }
            continue;
        }

        // Route: Logout
        if (std.mem.eql(u8, target, "/logout")) {
            handleLogout(&request, allocator, database) catch return;
            continue;
        }

        // Route: Favicon
        if (std.mem.eql(u8, target, "/favicon.ico")) {
            const file_content = std.Io.Dir.cwd().readFileAlloc(io, "public/favicon.ico", allocator, @enumFromInt(1024 * 1024)) catch null;
            if (file_content) |content| {
                request.respond(content, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "image/x-icon" },
                    },
                }) catch return;
            } else {
                request.respond("Not found", .{ .status = .not_found }) catch return;
            }
            continue;
        }

        // --- Auth middleware: all remaining routes require a valid session ---
        const session_token = extractCookieToken(&request);
        const session_info = if (session_token) |token|
            session_mod.getSession(database, allocator, token) catch null
        else
            null;

        if (session_info == null) {
            // Not authenticated — redirect to login
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
                    .{ .name = "content-type", .value = "text/html" },
                },
            }) catch return;

        // Route: Add Library
        } else if (std.mem.startsWith(u8, target, "/libraries/add") and method == .POST) {
            handleLibraryAdd(&request, allocator, database, &resp_buf) catch return;
            continue;

        // Route: Browse Specific Library
        } else if (std.mem.startsWith(u8, target, "/library")) {
            var lib_id: i64 = -1;
            if (std.mem.indexOf(u8, target, "?")) |q_idx| {
                const query = target[q_idx + 1 ..];
                var it = std.mem.splitScalar(u8, query, '&');
                while (it.next()) |param| {
                    if (std.mem.startsWith(u8, param, "id=")) {
                        lib_id = std.fmt.parseInt(i64, param[3..], 10) catch -1;
                    }
                }
            }

            if (lib_id != -1) {
                const html_content = catalog.generateLibraryContentHtml(allocator, io, database, lib_id) catch |err| {
                    std.debug.print("Browse Library content error: {}\n", .{err});
                    if (err == error.LibraryPathNotFound) {
                        request.respond("Library path not found or inaccessible.", .{ .status = .not_found }) catch return;
                    } else {
                        request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                    }
                    return;
                };

                if (html_content) |content| {
                    request.respond(content, .{
                        .status = .ok,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "text/html" },
                        },
                    }) catch return;
                } else {
                    request.respond("Library not found", .{ .status = .not_found }) catch return;
                }
            } else {
                request.respond("Missing library id", .{ .status = .bad_request }) catch return;
            }

        // Route: Web UI (Player)
        } else if (std.mem.startsWith(u8, target, "/player")) {
            var file_path_opt: ?[]const u8 = null;
            var lib_id: i64 = -1;
            if (std.mem.indexOf(u8, target, "?")) |q_idx| {
                const query = target[q_idx + 1 ..];
                var it = std.mem.splitScalar(u8, query, '&');
                while (it.next()) |param| {
                    if (std.mem.startsWith(u8, param, "file=")) {
                        file_path_opt = param[5..];
                    } else if (std.mem.startsWith(u8, param, "library=")) {
                        lib_id = std.fmt.parseInt(i64, param[8..], 10) catch -1;
                    }
                }
            }

            if (file_path_opt) |file_path| {
                var resolved_wf = allocator.dupe(u8, working_folder) catch return;
                if (lib_id != -1) {
                    if (library_mod.getLibraryById(database, allocator, lib_id) catch null) |lib| {
                        allocator.free(resolved_wf);
                        resolved_wf = allocator.dupe(u8, lib.path) catch return;
                        allocator.free(lib.name);
                        allocator.free(lib.path);
                        allocator.free(lib.metadata_language);
                        if (lib.ignore_patterns) |pat| allocator.free(pat);
                    }
                }

                const decoded_path = allocator.dupe(u8, file_path) catch return;
                const final_path = std.Uri.percentDecodeInPlace(decoded_path);

                const full_path = std.fs.path.join(allocator, &[_][]const u8{ resolved_wf, final_path }) catch return;
                const resolved_path = std.fs.path.resolve(allocator, &[_][]const u8{ full_path }) catch return;
                const abs_wf_path = std.fs.path.resolve(allocator, &[_][]const u8{ resolved_wf }) catch return;
                
                allocator.free(resolved_wf);

                if (!std.mem.startsWith(u8, resolved_path, abs_wf_path)) {
                    request.respond("Forbidden", .{ .status = .forbidden }) catch return;
                    return;
                }

                // Ensure null-terminated string for C API
                const c_full_path = allocator.dupeZ(u8, resolved_path) catch return;

                const media_info = streamer.getMediaInfo(allocator, c_full_path) catch streamer.MediaInfo{
                    .duration = 2799.0,
                    .codec_str = "video/mp4; codecs=\"avc1.4d401e, mp4a.40.2\"",
                    .audio_tracks = &[_]streamer.AudioTrack{},
                };

                var json_out: std.ArrayList(u8) = .empty;
                defer json_out.deinit(allocator);
                json_out.appendSlice(allocator, "[") catch return;
                for (media_info.audio_tracks, 0..) |track, i| {
                    if (i > 0) json_out.appendSlice(allocator, ",") catch return;
                    
                    // Escape quotes just in case
                    var safe_label: std.ArrayList(u8) = .empty;
                    defer safe_label.deinit(allocator);
                    for (track.label) |ch| {
                        if (ch == '"' or ch == '\\') {
                            safe_label.append(allocator, '\\') catch return;
                        }
                        safe_label.append(allocator, ch) catch return;
                    }
                    
                    const track_str = std.fmt.allocPrint(allocator, "{{\"id\":{},\"label\":\"{s}\"}}", .{ track.id, safe_label.items }) catch return;
                    json_out.appendSlice(allocator, track_str) catch return;
                }
                json_out.appendSlice(allocator, "]") catch return;
                const audio_tracks_json = json_out.items;

                const html_content = html.generatePlayerHtml(allocator, final_path, media_info.duration, media_info.codec_str, audio_tracks_json) catch return;

                request.respond(html_content, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/html" },
                    },
                }) catch return;
            } else {
                request.respond("Missing file parameter", .{ .status = .bad_request }) catch return;
            }
            
        // Route: Media Streamer
        } else if (std.mem.startsWith(u8, target, "/stream")) {
            // Parse query parameters
            var file_path_opt: ?[]const u8 = null;
            var lib_id: i64 = -1;
            var start_time: f64 = 0;
            var audio_idx: c_int = -1;

            if (std.mem.indexOf(u8, target, "?")) |q_idx| {
                const query = target[q_idx + 1 ..];
                var it = std.mem.splitScalar(u8, query, '&');
                while (it.next()) |param| {
                    if (std.mem.startsWith(u8, param, "file=")) {
                        file_path_opt = param[5..];
                    } else if (std.mem.startsWith(u8, param, "library=")) {
                        lib_id = std.fmt.parseInt(i64, param[8..], 10) catch -1;
                    } else if (std.mem.startsWith(u8, param, "start=")) {
                        start_time = std.fmt.parseFloat(f64, param[6..]) catch 0;
                    } else if (std.mem.startsWith(u8, param, "audio=")) {
                        audio_idx = std.fmt.parseInt(c_int, param[6..], 10) catch -1;
                    }
                }
            }

            if (file_path_opt) |file_path| {
                var resolved_wf = allocator.dupe(u8, working_folder) catch return;
                if (lib_id != -1) {
                    if (library_mod.getLibraryById(database, allocator, lib_id) catch null) |lib| {
                        allocator.free(resolved_wf);
                        resolved_wf = allocator.dupe(u8, lib.path) catch return;
                        allocator.free(lib.name);
                        allocator.free(lib.path);
                        allocator.free(lib.metadata_language);
                        if (lib.ignore_patterns) |pat| allocator.free(pat);
                    }
                }

                const decoded_path = allocator.dupe(u8, file_path) catch return;
                const final_path = std.Uri.percentDecodeInPlace(decoded_path);

                // Ensure the path is prefixed with working_folder to avoid reading absolute OS paths securely
                const full_path = std.fs.path.join(allocator, &[_][]const u8{ resolved_wf, final_path }) catch return;
                const resolved_path = std.fs.path.resolve(allocator, &[_][]const u8{ full_path }) catch return;
                const abs_wf_path = std.fs.path.resolve(allocator, &[_][]const u8{ resolved_wf }) catch return;
                
                allocator.free(resolved_wf);

                if (!std.mem.startsWith(u8, resolved_path, abs_wf_path)) {
                    request.respond("Forbidden", .{ .status = .forbidden }) catch return;
                    return;
                }

                // Initialize chunked response for MP4 stream
                var resp = request.respondStreaming(&resp_buf, .{
                    .respond_options = .{
                        .status = .ok,
                        .extra_headers = &.{
                            .{ .name = "content-type", .value = "video/mp4" },
                            .{ .name = "access-control-allow-origin", .value = "*" },
                        },
                    },
                }) catch return;

                // Fire up FFmpeg pipeline
                var stream_ctx = streamer.HttpStreamContext{ .writer = &resp };
                streamer.streamMedia(resolved_path, start_time, audio_idx, &stream_ctx) catch |e| {
                    if (e != error.ConnectionDropped) {
                        std.debug.print("Stream error: {}\n", .{e});
                    }
                    return; // Drop the connection silently if it was just dropped by the client
                };
                
                resp.end() catch return;
            } else {
                request.respond("Missing file parameter", .{ .status = .bad_request }) catch return;
            }
        } else {
            request.respond("Not found", .{ .status = .not_found }) catch return;
        }
    }
}

/// Serves the login HTML page with an optional error message.
fn serveLoginPage(request: *std.http.Server.Request, allocator: std.mem.Allocator, error_message: []const u8) !void {
    const show_error = if (error_message.len > 0) "block" else "none";
    const msg = if (error_message.len > 0) error_message else "";

    const html_content = try template_engine.render(allocator, @embedFile("login.html"), .{
        .ERROR_DISPLAY = show_error,
        .ERROR_MESSAGE = msg,
    });

    request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html" },
        },
    }) catch return;
}

/// Handles POST /login — validates credentials and creates a session.
fn handleLoginPost(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, body_buf: *[8192]u8, io: std.Io) !void {
    // Read request body
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    // Parse form data (application/x-www-form-urlencoded)
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    var pairs = std.mem.splitScalar(u8, body_data.items, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "username=")) {
            const raw = pair[9..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            username = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "password=")) {
            const raw = pair[9..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            password = std.Uri.percentDecodeInPlace(decoded);
        }
    }

    if (username == null or password == null) {
        try serveLoginPage(request, allocator, "Please enter both username and password.");
        return;
    }

    // Verify credentials
    const valid = users_mod.verifyPassword(database, allocator, username.?, password.?) catch false;
    if (!valid) {
        try serveLoginPage(request, allocator, "Invalid username or password.");
        return;
    }

    // Check if user is admin
    const is_admin = users_mod.isAdmin(database, username.?) catch false;

    // Create session
    const token = try session_mod.createSession(database, allocator, io, username.?, is_admin);
    const cookie_value = try std.fmt.allocPrint(allocator, "session={s}; Path=/; HttpOnly; SameSite=Strict", .{token});

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = "/" },
            .{ .name = "set-cookie", .value = cookie_value },
        },
    }) catch return;
}

/// Handles POST /libraries/add — validates library config and inserts to DB.
fn handleLibraryAdd(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, body_buf: *[8192]u8) !void {
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
            name = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "path=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            path = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "type=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            type_str = std.Uri.percentDecodeInPlace(decoded);
        }
    }

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

/// Handles GET /logout — destroys session and redirects.
fn handleLogout(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database) !void {
    const token = extractCookieToken(request);
    if (token) |t| {
        session_mod.destroySession(database, t) catch {};
    }
    _ = allocator;

    request.respond("", .{
        .status = .found,
        .extra_headers = &.{
            .{ .name = "location", .value = "/login" },
            .{ .name = "set-cookie", .value = "session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" },
        },
    }) catch return;
}

/// Extracts the session token from Cookie headers.
fn extractCookieToken(request: *std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) {
            var cookie_it = std.mem.splitSequence(u8, header.value, "; ");
            while (cookie_it.next()) |cookie| {
                if (std.mem.startsWith(u8, cookie, "session=")) {
                    return cookie[8..];
                }
            }
        }
    }
    return null;
}
