const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const subtitles_mod = @import("../../../media/subtitles.zig");
const utils = @import("../../utils.zig");
const common = @import("common.zig");

fn DualWriter(comptime W1: type, comptime W2: type) type {
    return struct {
        w1: W1,
        w2: W2,

        pub const Error = anyerror;

        pub fn writeAll(self: *@This(), bytes: []const u8) !void {
            self.w1.writeAll(bytes) catch {};
            try self.w2.writeAll(bytes);
        }

        pub fn print(self: *@This(), comptime format: []const u8, args: anytype) !void {
            var buf: [256]u8 = undefined;
            const formatted = try std.fmt.bufPrint(&buf, format, args);
            try self.writeAll(formatted);
        }
    };
}

/// Handles the subtitle endpoint (/subtitles).
pub fn handleSubtitles(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    working_folder: []const u8,
    io: std.Io,
) !void {
    if (request.head.method == .OPTIONS) {
        try request.respond("", .{
            .status = .no_content,
            .extra_headers = &.{
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-allow-methods", .value = "GET, OPTIONS" },
                .{ .name = "access-control-allow-headers", .value = "content-type" },
            },
        });
        return;
    }

    const target = request.head.target;
    const movie_id = utils.parseQueryInt(i64, target, "id");
    const episode_id = utils.parseQueryInt(i64, target, "episode_id");
    const track_idx = utils.parseQueryInt(usize, target, "track");
    const start_offset = utils.parseQueryFloat(target, "start") orelse utils.parseQueryFloat(target, "offset") orelse 0.0;

    if ((movie_id == null and episode_id == null) or track_idx == null) {
        try request.respond("Missing parameters", .{ .status = .bad_request });
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

    // Ensure cache directory exists
    std.Io.Dir.cwd().createDirPath(io, ".sratim/cache/subs") catch {};

    const cache_filename = if (movie_id != null)
        try std.fmt.allocPrint(allocator, ".sratim/cache/subs/m_{d}_{d}.vtt", .{ movie_id.?, track_idx.? })
    else
        try std.fmt.allocPrint(allocator, ".sratim/cache/subs/e_{d}_{d}.vtt", .{ episode_id.?, track_idx.? });
    defer allocator.free(cache_filename);

    const cached_vtt = std.Io.Dir.cwd().readFileAlloc(io, cache_filename, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch null;
    if (cached_vtt) |vtt_data| {
        defer allocator.free(vtt_data);
        if (vtt_data.len > 0) {
            try request.respond(vtt_data, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "text/vtt; charset=utf-8" },
                    .{ .name = "access-control-allow-origin", .value = "*" },
                    .{ .name = "cache-control", .value = "public, max-age=86400" },
                },
            });
            return;
        }
    }

    const c_full_path = try allocator.dupeZ(u8, resolved.?.resolved_path);
    defer allocator.free(c_full_path);

    const resp_buf = try allocator.alloc(u8, 8192);
    defer allocator.free(resp_buf);

    var resp = try request.respondStreaming(resp_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/vtt; charset=utf-8" },
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "x-accel-buffering", .value = "no" },
                .{ .name = "cache-control", .value = "public, max-age=86400" },
            },
        },
    });

    var vtt_allocating = std.Io.Writer.Allocating.init(allocator);
    defer vtt_allocating.deinit();

    var dual_writer = DualWriter(@TypeOf(&resp.writer), @TypeOf(&vtt_allocating.writer)){
        .w1 = &resp.writer,
        .w2 = &vtt_allocating.writer,
    };

    subtitles_mod.extractSubtitlesVtt(allocator, io, &dual_writer, c_full_path, track_idx.?, start_offset) catch |err| {
        std.debug.print("Subtitle extraction error: {}\n", .{err});
    };

    resp.end() catch {};

    const vtt_bytes = vtt_allocating.written();
    if (vtt_bytes.len > 0 and start_offset == 0.0) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache_filename, .data = vtt_bytes }) catch {};
    }
}
