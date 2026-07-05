const std = @import("std");
const Config = @import("config.zig").Config;
const indexer = @import("indexer.zig");

const ffprobe = @import("ffprobe.zig");
const player = @import("player.zig");
const manifest = @import("manifest.zig");
const packager = @import("packager.zig");

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

        handleRequest(allocator, io, &request, config) catch |err| {
            if (err != error.ConnectionResetByPeer and err != error.BrokenPipe and err != error.WriteFailed and err != error.SocketUnconnected) {
                std.debug.print("Request error: {}\n", .{err});
            }
        };
    }
}

fn handleRequest(allocator: std.mem.Allocator, io: std.Io, request: *std.http.Server.Request, config: *const Config) !void {
    std.debug.print("Target received: '{s}'\n", .{request.head.target});
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
    } else if (std.mem.startsWith(u8, request.head.target, "/manifest.mpd?file=")) {
        const raw_file_param = request.head.target["/manifest.mpd?file=".len..];
        const decoded_file_buf = try allocator.alloc(u8, raw_file_param.len);
        defer allocator.free(decoded_file_buf);
        const file_param = std.Uri.percentDecodeBackwards(decoded_file_buf, raw_file_param);
        
        const full_path = try std.fs.path.join(allocator, &.{ config.working_folder, file_param });
        defer allocator.free(full_path);

        const cache_dir = try std.fs.path.join(allocator, &.{ config.working_folder, ".sratim", "manifests" });
        defer allocator.free(cache_dir);
        std.Io.Dir.cwd().createDirPath(io, cache_dir) catch {};

        const hash = std.hash.CityHash64.hash(full_path);
        const cache_file = try std.fmt.allocPrint(allocator, "{s}/{d}.mpd", .{ cache_dir, hash });
        defer allocator.free(cache_file);

        const splits_file = try std.fmt.allocPrint(allocator, "{s}/{d}.splits", .{ cache_dir, hash });
        defer allocator.free(splits_file);

        var xml: []const u8 = undefined;
        if (std.Io.Dir.cwd().readFileAlloc(io, cache_file, allocator, .unlimited)) |cached_xml| {
            xml = cached_xml;
        } else |_| {
            const result = manifest.generateMpd(allocator, full_path, raw_file_param) catch |err| {
                std.debug.print("Failed to generate MPD: {}\n", .{err});
                try request.respond("Internal Server Error or File Not Found", .{ .status = .internal_server_error });
                return;
            };
            xml = result.xml;
            
            // Save MPD cache
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache_file, .data = xml }) catch |err| {
                std.debug.print("Failed to write MPD cache: {}\n", .{err});
            };
            
            // Save splits file
            if (result.splits.len > 0) {
                std.Io.Dir.cwd().writeFile(io, .{ .sub_path = splits_file, .data = std.mem.sliceAsBytes(result.splits) }) catch |err| {
                    std.debug.print("Failed to write splits file: {}\n", .{err});
                };
            }
            allocator.free(result.splits);
        }
        defer allocator.free(xml);

        try request.respond(xml, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/dash+xml; charset=utf-8" },
            },
        });
    } else if (std.mem.startsWith(u8, request.head.target, "/api/stream/")) {
        const stream_path = request.head.target["/api/stream/".len..];
        
        var iter = std.mem.splitScalar(u8, stream_path, '/');
        const raw_file_param = iter.next() orelse "";
        const stream_type = iter.next() orelse "";
        
        const decoded_file_buf = try allocator.alloc(u8, raw_file_param.len);
        defer allocator.free(decoded_file_buf);
        const file_param = std.Uri.percentDecodeBackwards(decoded_file_buf, raw_file_param);
        
        const full_path = try std.fs.path.join(allocator, &.{ config.working_folder, file_param });
        defer allocator.free(full_path);
        
        var track_index: usize = 0;
        var filename = iter.next() orelse "";
        
        if (std.mem.eql(u8, stream_type, "audio")) {
            const track_str = filename;
            track_index = std.fmt.parseInt(usize, track_str, 10) catch 0;
            filename = iter.next() orelse "";
        }
        
        const is_audio = std.mem.eql(u8, stream_type, "audio");
        const is_init = std.mem.eql(u8, filename, "init.mp4");
        
        var chunk_index: usize = 0;
        if (!is_init) {
            if (std.mem.startsWith(u8, filename, "chunk_") and std.mem.endsWith(u8, filename, ".m4s")) {
                const num_str = filename["chunk_".len .. filename.len - ".m4s".len];
                chunk_index = std.fmt.parseInt(usize, num_str, 10) catch 0;
            }
        }
        
        const cache_dir = try std.fs.path.join(allocator, &.{ config.working_folder, ".sratim", "manifests" });
        defer allocator.free(cache_dir);
        const hash = std.hash.CityHash64.hash(full_path);
        const splits_file = try std.fmt.allocPrint(allocator, "{s}/{d}.splits", .{ cache_dir, hash });
        defer allocator.free(splits_file);

        var splits_data: []const u8 = "";
        if (std.Io.Dir.cwd().readFileAlloc(io, splits_file, allocator, .unlimited)) |data| {
            splits_data = data;
        } else |err| {
            std.debug.print("Failed to read splits file {s}: {}\n", .{ splits_file, err });
        }
        var splits: []i64 = &[_]i64{};
        defer if (splits_data.len > 0) allocator.free(splits_data);
        if (splits_data.len > 0) {
            splits = allocator.alloc(i64, splits_data.len / @sizeOf(i64)) catch &[_]i64{};
            if (splits.len > 0) {
                @memcpy(std.mem.sliceAsBytes(splits), splits_data);
            }
        }
        defer if (splits.len > 0) allocator.free(splits);

        const chunk_data = packager.generateChunk(allocator, full_path, is_audio, track_index, chunk_index, is_init, splits) catch |err| {
            std.debug.print("Packager error: {}\n", .{err});
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
            return;
        };
        defer allocator.free(chunk_data);
        
        const content_type = if (is_audio) "audio/mp4" else "video/mp4";
        try request.respond(chunk_data, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
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
    } else if (std.mem.startsWith(u8, request.head.target, "/player?file=")) {
        const raw_file_param = request.head.target["/player?file=".len..];
        const html = try player.generatePlayerHtml(allocator, raw_file_param);
        defer allocator.free(html);

        try request.respond(html, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
    } else if (std.mem.startsWith(u8, request.head.target, "/shaka/")) {
        const file_path = request.head.target[1..]; // removes leading slash, becomes "shaka/..."
        const full_path = try std.fs.path.join(allocator, &.{ "public", file_path });
        defer allocator.free(full_path);

        const contents = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch |err| {
            if (err != error.FileNotFound) {
                std.debug.print("Failed to read static file {s}: {}\n", .{full_path, err});
            }
            try request.respond("Not Found", .{ .status = .not_found });
            return;
        };
        defer allocator.free(contents);
        
        const content_type = if (std.mem.endsWith(u8, file_path, ".css")) "text/css"
                            else if (std.mem.endsWith(u8, file_path, ".js")) "application/javascript"
                            else "text/plain";
                            
        try request.respond(contents, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = content_type },
            },
        });
    } else {
        try request.respond("Not Found", .{ .status = .not_found });
    }
}
