const std = @import("std");
const html = @import("html.zig");
const streamer = @import("streamer.zig");
const catalog = @import("catalog.zig");

/// Handles an incoming HTTP connection from a client.
/// This function runs inside an isolated OS thread spawned specifically for this connection.
/// It parses headers, routes endpoints, and serves content synchronously.
pub fn handleConnection(stream: std.Io.net.Stream, io: std.Io, working_folder: []const u8) void {
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

        // Route: Catalog (Home Page)
        if (std.mem.eql(u8, target, "/")) {
            const html_content = catalog.generateHtml(allocator, io, working_folder) catch |err| {
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

        // Route: Web UI (Player)
        } else if (std.mem.startsWith(u8, target, "/player")) {
            var file_path_opt: ?[]const u8 = null;
            if (std.mem.indexOf(u8, target, "?")) |q_idx| {
                const query = target[q_idx + 1 ..];
                var it = std.mem.splitScalar(u8, query, '&');
                while (it.next()) |param| {
                    if (std.mem.startsWith(u8, param, "file=")) {
                        file_path_opt = param[5..];
                    }
                }
            }

            if (file_path_opt) |file_path| {
                const decoded_path = allocator.dupe(u8, file_path) catch return;
                const final_path = std.Uri.percentDecodeInPlace(decoded_path);

                const full_path = std.fs.path.join(allocator, &[_][]const u8{ working_folder, final_path }) catch return;
                const resolved_path = std.fs.path.resolve(allocator, &[_][]const u8{ full_path }) catch return;
                const resolved_wf = std.fs.path.resolve(allocator, &[_][]const u8{ working_folder }) catch return;
                if (!std.mem.startsWith(u8, resolved_path, resolved_wf)) {
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
            
        // Route: Favicon
        } else if (std.mem.eql(u8, target, "/favicon.ico")) {
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
            
        // Route: Media Streamer
        } else if (std.mem.startsWith(u8, target, "/stream")) {
            // Parse query parameters
            var file_path_opt: ?[]const u8 = null;
            var start_time: f64 = 0;
            var audio_idx: c_int = -1;

            if (std.mem.indexOf(u8, target, "?")) |q_idx| {
                const query = target[q_idx + 1 ..];
                var it = std.mem.splitScalar(u8, query, '&');
                while (it.next()) |param| {
                    if (std.mem.startsWith(u8, param, "file=")) {
                        file_path_opt = param[5..];
                    } else if (std.mem.startsWith(u8, param, "start=")) {
                        start_time = std.fmt.parseFloat(f64, param[6..]) catch 0;
                    } else if (std.mem.startsWith(u8, param, "audio=")) {
                        audio_idx = std.fmt.parseInt(c_int, param[6..], 10) catch -1;
                    }
                }
            }

            if (file_path_opt) |file_path| {
                const decoded_path = allocator.dupe(u8, file_path) catch return;
                const final_path = std.Uri.percentDecodeInPlace(decoded_path);

                // Ensure the path is prefixed with working_folder to avoid reading absolute OS paths securely
                const full_path = std.fs.path.join(allocator, &[_][]const u8{ working_folder, final_path }) catch return;
                const resolved_path = std.fs.path.resolve(allocator, &[_][]const u8{ full_path }) catch return;
                const resolved_wf = std.fs.path.resolve(allocator, &[_][]const u8{ working_folder }) catch return;
                if (!std.mem.startsWith(u8, resolved_path, resolved_wf)) {
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
