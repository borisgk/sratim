const std = @import("std");
const Config = @import("config.zig").Config;
const indexer = @import("indexer.zig");

const ffprobe = @import("ffprobe.zig");

pub fn runServer(allocator: std.mem.Allocator, io: std.Io, config: *const Config) !void {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", config.port);
    var net_server = try address.listen(io, .{ .reuse_address = true });
    defer net_server.deinit(io);

    std.debug.print("Server listening on http://127.0.0.1:{d}\n", .{config.port});

    while (true) {
        var connection = net_server.accept(io) catch |err| {
            std.debug.print("Failed to accept connection: {}\n", .{err});
            continue;
        };
        defer connection.close(io);

        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;

        var stream_reader = std.Io.net.Stream.Reader.init(connection, io, &read_buffer);
        var stream_writer = std.Io.net.Stream.Writer.init(connection, io, &write_buffer);

        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);

        var request = http_server.receiveHead() catch |err| {
            if (err != error.HttpConnectionClosing and err != error.ConnectionResetByPeer) {
                std.debug.print("Failed to read head: {}\n", .{err});
            }
            continue;
        };

        try handleRequest(allocator, io, &request, config);
    }
}

fn handleRequest(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, config: *const Config) !void {
    if (std.mem.eql(u8, request.head.target, "/")) {
        const html = indexer.generateHtmlListing(allocator, io, config.working_folder) catch |err| {
            std.debug.print("Failed to generate HTML: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
            return;
        };
        defer allocator.free(html);

        try request.respond(html, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
    } else if (std.mem.startsWith(u8, request.head.target, "/info?file=")) {
        const raw_file_param = request.head.target["/info?file=".len..];
        const decoded_file_buf = try allocator.alloc(u8, raw_file_param.len);
        defer allocator.free(decoded_file_buf);
        const file_param = std.Uri.percentDecodeBackwards(decoded_file_buf, raw_file_param);
        
        const full_path = try std.fs.path.join(allocator, &.{ config.working_folder, file_param });
        defer allocator.free(full_path);

        const html = ffprobe.getProbeHtml(allocator, full_path) catch |err| {
            std.debug.print("Failed to probe file: {}\n", .{err});
            try request.respond("Internal Server Error or File Not Found", .{ .status = .internal_server_error });
            return;
        };
        defer allocator.free(html);

        try request.respond(html, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
    } else {
        try request.respond("Not Found", .{ .status = .not_found });
    }
}
