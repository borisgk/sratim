const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const utils = @import("../../utils.zig");
const common = @import("common.zig");

pub fn handleRawPlay(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    working_folder: []const u8,
    resp_buf: []u8,
    io: std.Io,
) !void {
    if (request.head.method == .OPTIONS) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = &.{
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS, HEAD" },
                .{ .name = "access-control-allow-headers", .value = "Range, Content-Type, Authorization" },
                .{ .name = "access-control-max-age", .value = "86400" },
            },
        });
        return;
    }

    if (request.head.method != .GET and request.head.method != .HEAD) {
        try request.respond("Method not allowed", .{ .status = .method_not_allowed });
        return;
    }

    const target = request.head.target;
    const movie_id = utils.parseQueryInt(i64, target, "id");
    const episode_id = utils.parseQueryInt(i64, target, "episode_id");

    if (movie_id == null and episode_id == null) {
        try request.respond("Missing id or episode_id parameter", .{ .status = .bad_request });
        return;
    }

    const media_info_opt = if (movie_id != null)
        metadata_mod.getMovieInfoById(database, allocator, movie_id.?) catch null
    else
        metadata_mod.getEpisodeInfoById(database, allocator, episode_id.?) catch null;

    const resolved = common.resolveMediaPath(database, allocator, media_info_opt, working_folder) catch |err| {
        if (err == error.PathTraversal) {
            try request.respond("Forbidden", .{ .status = .forbidden });
        } else {
            try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        }
        return;
    };
    if (resolved == null) {
        try request.respond("Media not found", .{ .status = .not_found });
        return;
    }
    defer {
        allocator.free(resolved.?.resolved_path);
        allocator.free(resolved.?.file_path);
    }

    const file_path = resolved.?.resolved_path;
    var file = std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only }) catch {
        try request.respond("File not found on disk", .{ .status = .not_found });
        return;
    };
    defer file.close(io);

    const stat = file.stat(io) catch {
        try request.respond("Internal Server Error", .{ .status = .internal_server_error });
        return;
    };
    const file_size = stat.size;

    var range_start: u64 = 0;
    var range_end: u64 = file_size - 1;
    var is_partial = false;

    var headers_iter = request.iterateHeaders();
    while (headers_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "range")) {
            const prefix = "bytes=";
            if (std.mem.startsWith(u8, header.value, prefix)) {
                const range_str = header.value[prefix.len..];
                var parts = std.mem.splitScalar(u8, range_str, '-');
                const start_str = parts.first();
                const end_str = parts.next() orelse "";

                if (start_str.len > 0) {
                    range_start = std.fmt.parseInt(u64, start_str, 10) catch 0;
                } else if (end_str.len > 0) {
                    const suffix_len = std.fmt.parseInt(u64, end_str, 10) catch 0;
                    if (suffix_len > file_size) {
                        range_start = 0;
                    } else {
                        range_start = file_size - suffix_len;
                    }
                    range_end = file_size - 1;
                    is_partial = true;
                    break;
                }
                
                if (end_str.len > 0 and start_str.len > 0) {
                    range_end = std.fmt.parseInt(u64, end_str, 10) catch (file_size - 1);
                }
                
                if (range_end >= file_size) {
                    range_end = file_size - 1;
                }
                is_partial = true;
            }
        }
    }

    if (range_start > range_end or range_start >= file_size) {
        try request.respond("Requested Range Not Satisfiable", .{
            .status = .range_not_satisfiable,
            .extra_headers = &.{
                .{ .name = "content-range", .value = try std.fmt.allocPrint(allocator, "bytes */{d}", .{file_size}) },
            },
        });
        return;
    }

    const chunk_size = range_end - range_start + 1;

    const ext = std.fs.path.extension(file_path);
    var content_type: []const u8 = "video/mp4";
    if (std.ascii.eqlIgnoreCase(ext, ".mkv")) {
        content_type = "video/x-matroska";
    } else if (std.ascii.eqlIgnoreCase(ext, ".webm")) {
        content_type = "video/webm";
    } else if (std.ascii.eqlIgnoreCase(ext, ".avi")) {
        content_type = "video/x-msvideo";
    }

    const content_range = try std.fmt.allocPrint(allocator, "bytes {d}-{d}/{d}", .{ range_start, range_end, file_size });
    const content_length_str = try std.fmt.allocPrint(allocator, "{d}", .{chunk_size});
    defer allocator.free(content_range);
    defer allocator.free(content_length_str);

    var extra_headers = std.ArrayList(std.http.Header).empty;
    defer extra_headers.deinit(allocator);

    try extra_headers.append(allocator, .{ .name = "content-type", .value = content_type });
    try extra_headers.append(allocator, .{ .name = "accept-ranges", .value = "bytes" });
    try extra_headers.append(allocator, .{ .name = "access-control-allow-origin", .value = "*" });
    try extra_headers.append(allocator, .{ .name = "content-length", .value = content_length_str });

    if (is_partial) {
        try extra_headers.append(allocator, .{ .name = "content-range", .value = content_range });
    }

    if (request.head.method == .HEAD) {
        try request.respond("", .{
            .status = if (is_partial) .partial_content else .ok,
            .extra_headers = extra_headers.items,
        });
        return;
    }

    var resp = try request.respondStreaming(resp_buf, .{
        .respond_options = .{
            .status = if (is_partial) .partial_content else .ok,
            .extra_headers = extra_headers.items,
        },
    });

    var remaining = chunk_size;
    var current_offset = range_start;
    var buffer: [32768]u8 = undefined;
    while (remaining > 0) {
        const to_read = @min(remaining, buffer.len);
        
        // Use readPositionalAll which returns number of bytes read (or handles short reads)
        // Wait, readPositionalAll returns usize
        const bytes_read = file.readPositionalAll(io, buffer[0..to_read], current_offset) catch break;
        if (bytes_read == 0) break;
        
        resp.writer.writeAll(buffer[0..bytes_read]) catch break;
        remaining -= bytes_read;
        current_offset += bytes_read;
    }

    resp.end() catch {};
}
