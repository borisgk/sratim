const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const streamer = @import("../../../media/streamer.zig");
const media_metadata = @import("../../../media/metadata.zig");
const config_mod = @import("../../../config.zig");
const utils = @import("../../utils.zig");
const common = @import("common.zig");
const isobmff = @import("../../../media/native/isobmff.zig");

/// Handles the media stream endpoint (/stream).
pub fn handleStream(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    io: std.Io,
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

    const resolved = common.resolveMediaPath(database, allocator, media_info_opt) catch |err| {
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
    var res_media = resolved.?;
    defer res_media.deinit(allocator);

    const start_time = utils.parseQueryFloat(target, "start") orelse 0;
    const audio_idx = utils.parseQueryInt(c_int, target, "audio") orelse -1;

    const actual_start = media_metadata.getKeyframePts(io, resolved.?.resolved_path, start_time, audio_idx, config.media_engine.metadata);
    var actual_start_buf: [32]u8 = undefined;
    const actual_start_str = try std.fmt.bufPrint(&actual_start_buf, "{d:.3}", .{actual_start});

    const is_native = (config.media_engine.streamer == .native);

    var resp = try request.respondStreaming(resp_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "video/mp4" },
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-expose-headers", .value = "x-actual-start-time, x-stream-engine" },
                .{ .name = "accept-ranges", .value = "bytes" },
                .{ .name = "x-actual-start-time", .value = actual_start_str },
                .{ .name = "x-stream-engine", .value = if (is_native) "native-fmp4" else "ffmpeg" },
            },
        },
    });

    var stream_ctx = streamer.HttpStreamContext{ .writer = &resp };
    // Use std.heap.c_allocator so that each GOP fragment and AAC frame buffer is freed to the OS heap immediately
    streamer.streamMedia(std.heap.c_allocator, io, resolved.?.resolved_path, start_time, audio_idx, &stream_ctx, config.media_engine.streamer) catch |e| {
        if (e != error.ConnectionDropped) {
            std.debug.print("Stream error: {}\n", .{e});
        }
        return;
    };

    if (!stream_ctx.has_error) {
        resp.end() catch {};
    }
}
