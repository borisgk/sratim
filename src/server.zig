const std = @import("std");
const html = @import("html.zig");
const streamer = @import("streamer.zig");

/// Handles an incoming HTTP connection from a client.
/// This function runs inside an isolated OS thread spawned specifically for this connection.
/// It parses headers, routes endpoints, and serves content synchronously.
pub fn handleConnection(stream: std.Io.net.Stream, io: std.Io) void {
    // Ensure the socket is always closed when this function exits, no matter what happens
    defer stream.socket.close(io);

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

        // Route: Web UI
        if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/player")) {
            request.respond(html.INDEX_HTML, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/html" },
                },
            }) catch return;
            
        // Route: Favicon
        } else if (std.mem.eql(u8, target, "/favicon.ico")) {
            const file_content = std.Io.Dir.cwd().readFileAlloc(io, "public/favicon.ico", std.heap.c_allocator, @enumFromInt(1024 * 1024)) catch null;
            if (file_content) |content| {
                defer std.heap.c_allocator.free(content);
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

            if (std.mem.indexOf(u8, target, "?")) |q_idx| {
                const query = target[q_idx + 1 ..];
                var it = std.mem.splitScalar(u8, query, '&');
                while (it.next()) |param| {
                    if (std.mem.startsWith(u8, param, "file=")) {
                        file_path_opt = param[5..];
                    } else if (std.mem.startsWith(u8, param, "start=")) {
                        start_time = std.fmt.parseFloat(f64, param[6..]) catch 0;
                    }
                }
            }

            if (file_path_opt) |file_path| {
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
                streamer.streamMedia(file_path, start_time, &stream_ctx) catch |e| {
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
