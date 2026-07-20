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
const auth_handler = @import("handlers/auth.zig");
const library_handler = @import("handlers/library.zig");
const browse_handler = @import("handlers/browse.zig");
const watch_handler = @import("handlers/watch.zig");
const metadata_handler = @import("handlers/metadata.zig");
const global_css = @embedFile("style.css");
const favicon_ico = @embedFile("favicon.ico");
const c = @import("../core/c.zig").c;

/// Parse an integer query parameter by name from a URL target string.
/// Returns null if the parameter is not found or cannot be parsed.
fn parseQueryInt(comptime T: type, target: []const u8, name: []const u8) ?T {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            return std.fmt.parseInt(T, param[name.len + 1 ..], 10) catch null;
        }
    }
    return null;
}

/// Parse a float query parameter by name from a URL target string.
fn parseQueryFloat(target: []const u8, name: []const u8) ?f64 {
    const q_idx = std.mem.indexOf(u8, target, "?") orelse return null;
    var it = std.mem.splitScalar(u8, target[q_idx + 1 ..], '&');
    while (it.next()) |param| {
        if (std.mem.startsWith(u8, param, name) and param.len > name.len and param[name.len] == '=') {
            return std.fmt.parseFloat(f64, param[name.len + 1 ..]) catch null;
        }
    }
    return null;
}

const ResolvedMovie = struct {
    resolved_path: []const u8,
    file_path: []const u8,
};

/// Resolves a movie's absolute file path from its database ID.
/// Looks up the movie, resolves the library base path, joins them,
/// and performs a path traversal check. Returns null if the movie
/// is not found; returns error on path resolution failures.
fn resolveMoviePath(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    movie_id: i64,
    working_folder: []const u8,
) !?ResolvedMovie {
    const info = metadata_mod.getMovieInfoById(database, allocator, movie_id) catch return null;
    if (info == null) return null;
    const movie_info = info.?;

    // Determine the base path: use the library path if available, otherwise fall back to working_folder
    var base_path = try allocator.dupe(u8, working_folder);
    if (library_mod.getLibraryById(database, allocator, movie_info.library_id) catch null) |lib| {
        allocator.free(base_path);
        base_path = try allocator.dupe(u8, lib.path);
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    const full_path = try std.fs.path.join(allocator, &[_][]const u8{ base_path, movie_info.file_path });
    const resolved_path = try std.fs.path.resolve(allocator, &[_][]const u8{full_path});
    const abs_base = try std.fs.path.resolve(allocator, &[_][]const u8{base_path});
    allocator.free(base_path);

    // Path traversal guard
    if (!std.mem.startsWith(u8, resolved_path, abs_base)) {
        return error.PathTraversal;
    }

    return ResolvedMovie{
        .resolved_path = resolved_path,
        .file_path = movie_info.file_path,
    };
}

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

        // Route: Stylesheet (fallback — CSS is now inlined into HTML)
        if (std.mem.startsWith(u8, target, "/style.css")) {
            request.respond(global_css, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/css; charset=utf-8" },
                    .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
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
                    .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                },
            }) catch return;
            continue;
        }

        // Route: TMDB Images
        if (std.mem.startsWith(u8, target, "/images/")) {
            // target could be /images/posters/w500/abc.jpg?t=123
            const query_idx = std.mem.indexOf(u8, target, "?");
            const clean_target = if (query_idx) |idx| target[0..idx] else target;
            const rel_path = clean_target["/images/".len..];
            
            const file_path = std.fmt.allocPrint(allocator, "images/{s}", .{rel_path}) catch {
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
                    .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                },
            }) catch return;
            continue;
        }

        // --- Auth middleware: all remaining routes require a valid session ---
        const session_token = auth_handler.extractCookieToken(&request);
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

        // Route: API Metadata Search
        } else if (std.mem.startsWith(u8, target, "/api/metadata/search") and method == .GET) {
            metadata_handler.handleApiMetadataSearch(&request, allocator, io, config) catch |err| {
                std.debug.print("API Metadata Search error: {}\n", .{err});
                request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                return;
            };
            continue;

        // Route: API Metadata Auto Link (must be before /api/metadata/link to avoid prefix match)
        } else if (std.mem.startsWith(u8, target, "/api/metadata/auto-link") and method == .POST) {
            metadata_handler.handleApiMetadataAutoLink(&request, allocator, io, database, config, &resp_buf) catch |err| {
                std.debug.print("API Metadata Auto Link error: {}\n", .{err});
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
            const lib_id = parseQueryInt(i64, target, "id") orelse {
                request.respond("Missing library id", .{ .status = .bad_request }) catch return;
                continue;
            };

            const html_content = catalog.generateLibraryContentHtml(allocator, io, database, logs_database, lib_id, session_info.?.username) catch |err| {
                std.debug.print("Browse Library content error: {}\n", .{err});
                if (err == error.LibraryPathNotFound) {
                    request.respond("Library path not found or inaccessible.", .{ .status = .not_found }) catch return;
                } else {
                    request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                }
                continue;
            };

            if (html_content) |content| {
                request.respond(content, .{
                    .status = .ok,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                    },
                }) catch return;
            } else {
                request.respond("Library not found", .{ .status = .not_found }) catch return;
            }

        } else if (std.mem.startsWith(u8, target, "/details")) {
            const movie_id = parseQueryInt(i64, target, "id") orelse {
                request.respond("Missing id param", .{ .status = .bad_request }) catch return;
                continue;
            };

            const html_content = catalog.generateDetailsHtml(allocator, database, logs_database, movie_id, session_info.?.username) catch |err| {
                std.debug.print("Details page error: {}\n", .{err});
                if (err == error.MovieNotFound) {
                    request.respond("Movie not found", .{ .status = .not_found }) catch return;
                } else {
                    request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                }
                continue;
            };

            request.respond(html_content, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                },
            }) catch return;

        // Route: Web UI (Player)
        } else if (std.mem.startsWith(u8, target, "/player")) {
            const movie_id = parseQueryInt(i64, target, "id") orelse {
                request.respond("Missing movie id parameter", .{ .status = .bad_request }) catch return;
                continue;
            };

            const resolved = resolveMoviePath(database, allocator, movie_id, working_folder) catch |err| {
                if (err == error.PathTraversal) {
                    request.respond("Forbidden", .{ .status = .forbidden }) catch return;
                } else {
                    request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                }
                continue;
            };
            if (resolved == null) {
                request.respond("Movie not found", .{ .status = .not_found }) catch return;
                continue;
            }

            // Ensure null-terminated string for C API
            const c_full_path = allocator.dupeZ(u8, resolved.?.resolved_path) catch return;

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

            const start_opt = parseQueryFloat(target, "start");
            const resume_pos = if (start_opt) |s| s else logging_mod.getPlaybackProgress(logs_database, session_info.?.username, movie_id) catch 0.0;
            const html_content = html.generatePlayerHtml(allocator, movie_id, media_info.duration, media_info.codec_str, audio_tracks_json, resume_pos) catch return;

            request.respond(html_content, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                },
            }) catch return;
            
        // Route: Media Streamer
        } else if (std.mem.startsWith(u8, target, "/stream")) {
            const movie_id = parseQueryInt(i64, target, "id") orelse {
                request.respond("Missing file parameter", .{ .status = .bad_request }) catch return;
                continue;
            };

            const resolved = resolveMoviePath(database, allocator, movie_id, working_folder) catch |err| {
                if (err == error.PathTraversal) {
                    request.respond("Forbidden", .{ .status = .forbidden }) catch return;
                } else {
                    request.respond("Internal Server Error", .{ .status = .internal_server_error }) catch return;
                }
                continue;
            };
            if (resolved == null) {
                request.respond("Movie not found", .{ .status = .not_found }) catch return;
                continue;
            }

            const start_time = parseQueryFloat(target, "start") orelse 0;
            const audio_idx = parseQueryInt(c_int, target, "audio") orelse -1;

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
            streamer.streamMedia(resolved.?.resolved_path, start_time, audio_idx, &stream_ctx) catch |e| {
                if (e != error.ConnectionDropped) {
                    std.debug.print("Stream error: {}\n", .{e});
                }
                return; // Drop the connection — stream is corrupted
            };
            
            resp.end() catch return;
        } else {
            request.respond("Not found", .{ .status = .not_found }) catch return;
        }
    }
}
