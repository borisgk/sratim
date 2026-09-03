const std = @import("std");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");
const streamer = @import("../../../media/streamer.zig");
const media_metadata = @import("../../../media/metadata.zig");
const config_mod = @import("../../../config.zig");
const utils = @import("../../utils.zig");
const common = @import("common.zig");
const isobmff = @import("../../../media/native/isobmff.zig");
const mp4_streamer = @import("../../../media/native/mp4_streamer.zig");
const mkv_streamer = @import("../../../media/native/mkv/mkv_streamer.zig");

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

    // Validate that media container and selected streams can be natively parsed and streamed
    const z_path = try allocator.dupeZ(u8, res_media.resolved_path);
    defer allocator.free(z_path);

    var is_supported = false;
    {
        const file = std.Io.Dir.cwd().openFile(io, z_path, .{ .mode = .read_only }) catch null;
        if (file) |f| {
            defer f.close(io);
            var file_buf: [1024]u8 = undefined;
            var file_reader = f.reader(io, &file_buf);
            var magic_buf: [16]u8 = undefined;
            const bytes_read = file_reader.interface.readSliceShort(&magic_buf) catch 0;
            if (bytes_read >= 8 and isobmff.isMp4Container(magic_buf[0..bytes_read])) {
                is_supported = mp4_streamer.canStreamMp4Natively(allocator, io, z_path, audio_idx);
            } else if (bytes_read >= 4 and magic_buf[0] == 0x1A and magic_buf[1] == 0x45 and magic_buf[2] == 0xDF and magic_buf[3] == 0xA3) {
                is_supported = mkv_streamer.canStreamMkvNatively(allocator, io, z_path, audio_idx);
            }
        }
    }

    if (!is_supported) {
        try request.respond("Unsupported media container or codec for native streaming.", .{
            .status = .unsupported_media_type,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
        });
        return;
    }

    const actual_start = media_metadata.getKeyframePts(io, resolved.?.resolved_path, start_time, audio_idx, config.media_engine.metadata);
    var actual_start_buf: [32]u8 = undefined;
    const actual_start_str = try std.fmt.bufPrint(&actual_start_buf, "{d:.3}", .{actual_start});

    const is_native = (config.media_engine.streamer == .native);
    const audio_mode_str = if (config.media_engine.audio_transcoder == .native) "native-aac" else "ffmpeg";

    var orig_audio_codec_buf: [64]u8 = undefined;
    var orig_audio_codec: []const u8 = "AAC";
    if (streamer.getMediaInfo(allocator, io, z_path, config.media_engine.metadata)) |minfo| {
        defer minfo.deinit(allocator);
        if (minfo.audio_tracks.len > 0) {
            var selected_codec: []const u8 = minfo.audio_tracks[0].codec;
            if (audio_idx >= 0) {
                for (minfo.audio_tracks) |at| {
                    if (at.id == @as(usize, @intCast(audio_idx))) {
                        selected_codec = at.codec;
                        break;
                    }
                }
            }
            orig_audio_codec = std.fmt.bufPrint(&orig_audio_codec_buf, "{s}", .{selected_codec}) catch "AAC";
        }
    } else |_| {}

    var resp = try request.respondStreaming(resp_buf, .{
        .respond_options = .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "video/mp4" },
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-expose-headers", .value = "x-actual-start-time, x-stream-engine, x-audio-engine, x-original-audio-codec" },
                .{ .name = "accept-ranges", .value = "bytes" },
                .{ .name = "x-actual-start-time", .value = actual_start_str },
                .{ .name = "x-stream-engine", .value = if (is_native) "native-fmp4" else "ffmpeg" },
                .{ .name = "x-audio-engine", .value = audio_mode_str },
                .{ .name = "x-original-audio-codec", .value = orig_audio_codec },
            },
        },
    });

    var stream_ctx = streamer.HttpStreamContext{ .writer = &resp };
    // Use std.heap.c_allocator so that each GOP fragment and AAC frame buffer is freed to the OS heap immediately
    streamer.streamMedia(std.heap.c_allocator, io, resolved.?.resolved_path, start_time, audio_idx, &stream_ctx, config.media_engine.streamer, config.media_engine.audio_transcoder) catch |e| {
        if (e != error.ConnectionDropped) {
            std.debug.print("Stream error: {}\n", .{e});
        }
        return;
    };

    if (!stream_ctx.has_error) {
        resp.end() catch {};
    }
}
