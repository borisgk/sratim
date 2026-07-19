const std = @import("std");
const html = @import("../core/html.zig");
const streamer = @import("../media/streamer.zig");
const catalog = @import("catalog.zig");
const db_mod = @import("../db/db.zig");
const users_mod = @import("../db/users.zig");
const session_mod = @import("../db/session.zig");
const template_engine = @import("../core/template.zig");
const library_mod = @import("../db/library.zig");
const logging_mod = @import("../db/logging.zig");
const config_mod = @import("../config.zig");
const tmdb = @import("../media/tmdb.zig");
const metadata_mod = @import("../db/metadata.zig");
const global_css = @embedFile("style.css");
const favicon_ico = @embedFile("favicon.ico");
const c = @import("../core/c.zig").c;

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
                handleLoginPost(&request, allocator, database, logs_database, &resp_buf, io) catch return;
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

        // Route: Stylesheet
        if (std.mem.startsWith(u8, target, "/style.css")) {
            request.respond(global_css, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/css" },
                },
            }) catch return;
            continue;
        }

        // Route: Favicon
        if (std.mem.startsWith(u8, target, "/favicon.ico")) {
            request.respond(favicon_ico, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "image/x-icon" },
                },
            }) catch return;
            continue;
        }

        // Route: TMDB Images
        if (std.mem.startsWith(u8, target, "/images/tmdb/")) {
            // target could be /images/tmdb/w500/abc.jpg?t=123
            const query_idx = std.mem.indexOf(u8, target, "?");
            const clean_target = if (query_idx) |idx| target[0..idx] else target;
            const rel_path = clean_target["/images/tmdb/".len..];
            
            const file_path = std.fmt.allocPrint(allocator, ".sratim/tmdb_images/{s}", .{rel_path}) catch {
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                continue;
            };
            defer allocator.free(file_path);
            
            const file_contents = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
                request.respond("Not Found", .{ .status = .not_found }) catch return;
                continue;
            };
            defer allocator.free(file_contents);
            
            request.respond(file_contents, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "image/jpeg" },
                },
            }) catch return;
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

        // Route: API Filesystem Browser
        } else if (std.mem.startsWith(u8, target, "/api/browse")) {
            handleApiBrowse(&request, allocator, io) catch |err| {
                std.debug.print("API Browse error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Playback Log / Progress Event
        } else if (std.mem.startsWith(u8, target, "/api/watch/event") and method == .POST) {
            handleApiWatchEvent(&request, allocator, logs_database, session_info.?.username, &resp_buf) catch |err| {
                std.debug.print("API Watch Event error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Playback Progress Modification (reset/watched)
        } else if (std.mem.startsWith(u8, target, "/api/watch/progress/update") and method == .POST) {
            handleApiWatchProgressUpdate(&request, allocator, database, logs_database, session_info.?.username, working_folder, &resp_buf) catch |err| {
                std.debug.print("API Watch Progress Update error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Metadata Search
        } else if (std.mem.startsWith(u8, target, "/api/metadata/search") and method == .GET) {
            handleApiMetadataSearch(&request, allocator, io, config) catch |err| {
                std.debug.print("API Metadata Search error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Metadata Auto Link (must be before /api/metadata/link to avoid prefix match)
        } else if (std.mem.startsWith(u8, target, "/api/metadata/auto-link") and method == .POST) {
            handleApiMetadataAutoLink(&request, allocator, io, database, config, &resp_buf) catch |err| {
                std.debug.print("API Metadata Auto Link error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Metadata Link
        } else if (std.mem.startsWith(u8, target, "/api/metadata/link") and method == .POST) {
            handleApiMetadataLink(&request, allocator, io, database, config, &resp_buf) catch |err| {
                std.debug.print("API Metadata Link error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
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
                const html_content = catalog.generateLibraryContentHtml(allocator, io, database, logs_database, lib_id, session_info.?.username) catch |err| {
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

                const resume_pos = logging_mod.getPlaybackProgress(logs_database, session_info.?.username, lib_id, final_path) catch 0.0;
                const html_content = html.generatePlayerHtml(allocator, final_path, media_info.duration, media_info.codec_str, audio_tracks_json, resume_pos) catch return;

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

    const html_content = try template_engine.render(allocator, @embedFile("templates/login.html"), .{
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
fn handleLoginPost(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, logs_database: *db_mod.Database, body_buf: *[8192]u8, io: std.Io) !void {
    var client_ip: []const u8 = "127.0.0.1";
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for") or std.ascii.eqlIgnoreCase(header.name, "x-real-ip")) {
            client_ip = header.value;
            break;
        }
    }

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
        if (username) |u| {
            logging_mod.logLoginAttempt(logs_database, u, "failed", client_ip) catch |err| {
                std.debug.print("Failed to log failed auth attempt: {}\n", .{err});
            };
        }
        try serveLoginPage(request, allocator, "Invalid username or password.");
        return;
    }

    // Check if user is admin
    const is_admin = users_mod.isAdmin(database, username.?) catch false;

    // Log successful login
    logging_mod.logLoginAttempt(logs_database, username.?, "success", client_ip) catch |err| {
        std.debug.print("Failed to log successful auth attempt: {}\n", .{err});
    };

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

/// Lists subdirectories of a given path for the file browser modal.
fn handleApiBrowse(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io) !void {
    var req_path_opt: ?[]const u8 = null;
    const target = request.head.target;
    if (std.mem.indexOf(u8, target, "?")) |q_idx| {
        const query = target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "path=")) {
                req_path_opt = param[5..];
            }
        }
    }

    var target_path: []const u8 = undefined;
    if (req_path_opt) |encoded_path| {
        const decoded = try allocator.dupe(u8, encoded_path);
        target_path = std.Uri.percentDecodeInPlace(decoded);
    } else {
        target_path = "";
    }

    var resolved_path: []const u8 = undefined;
    if (target_path.len == 0) {
        if (c.getenv("HOME")) |home| {
            resolved_path = try allocator.dupe(u8, std.mem.span(home));
        } else {
            resolved_path = try allocator.dupe(u8, "/");
        }
    } else {
        if (std.fs.path.resolve(allocator, &[_][]const u8{target_path})) |res| {
            resolved_path = res;
        } else |_| {
            if (c.getenv("HOME")) |home| {
                resolved_path = try allocator.dupe(u8, std.mem.span(home));
            } else {
                resolved_path = try allocator.dupe(u8, "/");
            }
        }
    }

    var dir_list = std.ArrayList([]const u8).empty;
    defer {
        for (dir_list.items) |d| allocator.free(d);
        dir_list.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(io, resolved_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open directory '{s}': {}\n", .{ resolved_path, err });
        try serveBrowseJson(request, allocator, resolved_path, &[_][]const u8{});
        return;
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            try dir_list.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    const sortFn = struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan;
    std.mem.sort([]const u8, dir_list.items, {}, sortFn);

    try serveBrowseJson(request, allocator, resolved_path, dir_list.items);
}

fn serveBrowseJson(request: *std.http.Server.Request, allocator: std.mem.Allocator, current: []const u8, dirs: []const []const u8) !void {
    const parent = std.fs.path.dirname(current) orelse "";

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"current\":\"");
    try escapeJsonString(&json, allocator, current);
    try json.appendSlice(allocator, "\",\"parent\":");
    if (parent.len > 0) {
        try json.appendSlice(allocator, "\"");
        try escapeJsonString(&json, allocator, parent);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, "null");
    }
    try json.appendSlice(allocator, ",\"directories\":[");
    for (dirs, 0..) |d, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try json.appendSlice(allocator, "\"");
        try escapeJsonString(&json, allocator, d);
        try json.appendSlice(allocator, "\"");
    }
    try json.appendSlice(allocator, "]}");

    request.respond(json.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return;
}

fn escapeJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
}

const WatchEventPayload = struct {
    library_id: i64,
    file: []const u8,
    event: []const u8,
    position: f64,
    duration: f64,
};

fn handleApiWatchEvent(request: *std.http.Server.Request, allocator: std.mem.Allocator, logs_database: *db_mod.Database, username: []const u8, body_buf: *[8192]u8) !void {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    const parsed = std.json.parseFromSlice(WatchEventPayload, allocator, body_data.items, .{}) catch |err| {
        std.debug.print("Failed to parse watch event JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    try logging_mod.logPlaybackEvent(logs_database, username, payload.library_id, payload.file, payload.event, payload.position);
    try logging_mod.savePlaybackProgress(logs_database, username, payload.library_id, payload.file, payload.position, payload.duration);

    request.respond("OK", .{ .status = .ok }) catch return;
}

const WatchProgressUpdatePayload = struct {
    library_id: i64,
    file: []const u8,
    action: []const u8,
};

fn handleApiWatchProgressUpdate(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, logs_database: *db_mod.Database, username: []const u8, working_folder: []const u8, body_buf: *[8192]u8) !void {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    const parsed = std.json.parseFromSlice(WatchProgressUpdatePayload, allocator, body_data.items, .{}) catch |err| {
        std.debug.print("Failed to parse watch progress update JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    if (std.mem.eql(u8, payload.action, "reset")) {
        try logging_mod.deletePlaybackProgress(logs_database, username, payload.library_id, payload.file);
    } else if (std.mem.eql(u8, payload.action, "watched")) {
        var resolved_wf = try allocator.dupe(u8, working_folder);
        if (payload.library_id != -1) {
            if (library_mod.getLibraryById(database, allocator, payload.library_id) catch null) |lib| {
                allocator.free(resolved_wf);
                resolved_wf = try allocator.dupe(u8, lib.path);
                allocator.free(lib.name);
                allocator.free(lib.path);
                allocator.free(lib.metadata_language);
                if (lib.ignore_patterns) |pat| allocator.free(pat);
            }
        }
        
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ resolved_wf, payload.file });
        const resolved_path = try std.fs.path.resolve(allocator, &[_][]const u8{ full_path });
        const abs_wf_path = try std.fs.path.resolve(allocator, &[_][]const u8{ resolved_wf });
        allocator.free(resolved_wf);

        if (!std.mem.startsWith(u8, resolved_path, abs_wf_path)) {
            request.respond("Forbidden", .{ .status = .forbidden }) catch return;
            return;
        }

        const c_full_path = try allocator.dupeZ(u8, resolved_path);
        const media_info = streamer.getMediaInfo(allocator, c_full_path) catch streamer.MediaInfo{
            .duration = 3600.0,
            .codec_str = "",
            .audio_tracks = &[_]streamer.AudioTrack{},
        };

        try logging_mod.savePlaybackProgress(logs_database, username, payload.library_id, payload.file, media_info.duration, media_info.duration);
    }

    request.respond("OK", .{ .status = .ok }) catch return;
}

fn handleApiMetadataSearch(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, config: *const config_mod.Config) !void {
    const token = config.tmdb_access_token orelse {
        request.respond("TMDB Access Token not configured in config.json", .{ .status = .bad_request }) catch return;
        return;
    };
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    var query: []const u8 = "";
    if (std.mem.indexOf(u8, request.head.target, "?")) |q_idx| {
        const params = request.head.target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, params, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "query=")) {
                query = param[6..];
            }
        }
    }

    if (query.len == 0) {
        request.respond("Missing query parameter", .{ .status = .bad_request }) catch return;
        return;
    }

    // Percent decode query
    const decoded_query = try allocator.dupe(u8, query);
    defer allocator.free(decoded_query);
    const clean_query = std.Uri.percentDecodeInPlace(decoded_query);

    var response_parsed = tmdb.searchMovie(allocator, io, clean_query, null, token, config.tmdb_proxy) catch |err| {
        std.debug.print("TMDB Search error: {}\n", .{err});
        request.respond("TMDB API request failed", .{ .status = .internal_server_error }) catch return;
        return;
    };
    defer response_parsed.deinit();

    // Stringify the results array
    var response_allocating = std.Io.Writer.Allocating.init(allocator);
    defer response_allocating.deinit();
    try std.json.Stringify.value(response_parsed.value.results, .{}, &response_allocating.writer);

    request.respond(response_allocating.written(), .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return;
}

const MetadataLinkPayload = struct {
    library_id: i64,
    file: []const u8,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    backdrop_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
};

fn handleApiMetadataLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    const parsed = std.json.parseFromSlice(MetadataLinkPayload, allocator, body_data.items, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse metadata link JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    // Download images locally before saving metadata
    tmdb.downloadImages(allocator, io, payload.poster_path, payload.backdrop_path, config.tmdb_proxy) catch |err| {
        std.debug.print("Failed to download images: {}\n", .{err});
    };

    try metadata_mod.saveMetadata(
        database,
        payload.library_id,
        payload.file,
        payload.tmdb_id,
        payload.title,
        payload.overview,
        payload.poster_path,
        payload.backdrop_path,
        payload.release_date,
    );

    request.respond("OK", .{ .status = .ok }) catch return;
}

fn parseYearAndCleanName(allocator: std.mem.Allocator, raw_name: []const u8) !struct { clean: []const u8, year: ?[]const u8 } {
    // Look for a 4-digit number (1800-2100) in the string
    var year_idx: ?usize = null;
    var i: usize = 0;
    while (i + 4 <= raw_name.len) : (i += 1) {
        const slice = raw_name[i .. i + 4];
        var is_digit = true;
        for (slice) |c_val| {
            if (!std.ascii.isDigit(c_val)) {
                is_digit = false;
                break;
            }
        }
        if (is_digit) {
            const year_val = try std.fmt.parseInt(u32, slice, 10);
            if (year_val >= 1800 and year_val <= 2100) {
                year_idx = i;
                break; // Found the first year-like digits
            }
        }
    }

    if (year_idx) |idx| {
        // Year found! Let's extract the clean name by taking everything before the year
        // and trimming any trailing spaces, dots, parentheses, or brackets.
        var name_end = idx;
        while (name_end > 0) {
            const last_char = raw_name[name_end - 1];
            if (last_char == ' ' or last_char == '.' or last_char == '(' or last_char == '[' or last_char == '-') {
                name_end -= 1;
            } else {
                break;
            }
        }
        
        const clean = std.mem.trim(u8, raw_name[0..name_end], " \t\r\n.-_");
        const year = raw_name[idx .. idx + 4];
        
        return .{
            .clean = try allocator.dupe(u8, clean),
            .year = try allocator.dupe(u8, year),
        };
    }

    // No year found, just clean the raw name
    const clean = std.mem.trim(u8, raw_name, " \t\r\n.-_");
    return .{
        .clean = try allocator.dupe(u8, clean),
        .year = null,
    };
}

const MetadataAutoLinkPayload = struct {
    library_id: i64,
    file: []const u8,
};

fn handleApiMetadataAutoLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    const token = config.tmdb_access_token orelse {
        request.respond("TMDB Access Token not configured in config.json", .{ .status = .bad_request }) catch return;
        return;
    };
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
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

    const parsed = std.json.parseFromSlice(MetadataAutoLinkPayload, allocator, body_data.items, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse metadata auto-link JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    // Get clean name from file path
    const basename = std.fs.path.basename(payload.file);
    const ext = std.fs.path.extension(basename);
    const clean_name = basename[0 .. basename.len - ext.len];

    const parsed_name = try parseYearAndCleanName(allocator, clean_name);
    defer allocator.free(parsed_name.clean);
    defer if (parsed_name.year) |y| allocator.free(y);

    // Search TMDB
    var response_parsed = tmdb.searchMovie(allocator, io, parsed_name.clean, parsed_name.year, token, config.tmdb_proxy) catch |err| {
        std.debug.print("TMDB Auto Search error: {}\n", .{err});
        request.respond("TMDB API request failed", .{ .status = .internal_server_error }) catch return;
        return;
    };
    defer response_parsed.deinit();

    if (response_parsed.value.results.len == 0) {
        request.respond("No metadata found for this movie name.", .{ .status = .not_found }) catch return;
        return;
    }

    const first_movie = response_parsed.value.results[0];

    // Download images locally before saving metadata
    tmdb.downloadImages(allocator, io, first_movie.poster_path, first_movie.backdrop_path, config.tmdb_proxy) catch |err| {
        std.debug.print("Failed to download images: {}\n", .{err});
    };

    try metadata_mod.saveMetadata(
        database,
        payload.library_id,
        payload.file,
        first_movie.id,
        first_movie.title,
        first_movie.overview,
        first_movie.poster_path,
        first_movie.backdrop_path,
        first_movie.release_date,
    );

    request.respond("OK", .{ .status = .ok }) catch return;
}

test "parseYearAndCleanName tests" {
    const allocator = std.testing.allocator;

    {
        const res = try parseYearAndCleanName(allocator, "Inception (2010)");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expectEqualStrings("2010", res.year.?);
    }

    {
        const res = try parseYearAndCleanName(allocator, "Inception.2010.1080p");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expectEqualStrings("2010", res.year.?);
    }

    {
        const res = try parseYearAndCleanName(allocator, "Inception");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expect(res.year == null);
    }
}
