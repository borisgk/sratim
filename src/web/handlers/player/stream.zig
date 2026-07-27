const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const streamer = @import("../../../media/streamer.zig");
const media_metadata = @import("../../../media/metadata.zig");
const utils = @import("../../utils.zig");
const common = @import("common.zig");

/// Handles the media stream endpoint (/stream).
pub fn handleStream(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    working_folder: []const u8,
    resp_buf: []u8,
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
        try request.respond("Movie not found", .{ .status = .not_found });
        return;
    }

    const start_time = utils.parseQueryFloat(target, "start") orelse 0;
    const audio_idx = utils.parseQueryInt(c_int, target, "audio") orelse -1;

    const actual_start = media_metadata.getKeyframePts(resolved.?.resolved_path, start_time, audio_idx);
    var actual_start_buf: [32]u8 = undefined;
    const actual_start_str = try std.fmt.bufPrint(&actual_start_buf, "{d:.3}", .{actual_start});

    var resp = try request.respondStreaming(resp_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "video/mp4" },
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-expose-headers", .value = "x-actual-start-time" },
                .{ .name = "accept-ranges", .value = "bytes" },
                .{ .name = "x-actual-start-time", .value = actual_start_str },
            },
        },
    });

    var stream_ctx = streamer.HttpStreamContext{ .writer = &resp };
    streamer.streamMedia(resolved.?.resolved_path, start_time, audio_idx, &stream_ctx) catch |e| {
        if (e != error.ConnectionDropped) {
            std.debug.print("Stream error: {}\n", .{e});
        }
        return;
    };

    if (!stream_ctx.has_error) {
        resp.end() catch {};
    }
}
