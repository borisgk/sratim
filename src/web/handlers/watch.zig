const std = @import("std");
const db_mod = @import("../../db/db.zig");
const logging_mod = @import("../../db/logging.zig");

const WatchEventPayload = struct {
    id: ?i64 = null,
    movie_id: ?i64 = null,
    episode_id: ?i64 = null,
    event: []const u8,
    position: f64,
    duration: f64,
};

pub fn handleApiWatchEvent(request: *std.http.Server.Request, allocator: std.mem.Allocator, logs_database: *db_mod.Database, username: []const u8, body_buf: *[8192]u8) !void {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    const parsed = std.json.parseFromSlice(WatchEventPayload, allocator, body_data.items, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse watch event JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;
    const target_movie_id = payload.movie_id orelse payload.id;

    if (target_movie_id) |movie_id| {
        try logging_mod.logPlaybackEvent(logs_database, username, movie_id, payload.event, payload.position);
        try logging_mod.savePlaybackProgress(logs_database, username, movie_id, payload.position, payload.duration);
    } else if (payload.episode_id) |episode_id| {
        try logging_mod.logEpisodePlaybackEvent(logs_database, username, episode_id, payload.event, payload.position);
        try logging_mod.saveEpisodePlaybackProgress(logs_database, username, episode_id, payload.position, payload.duration);
    } else {
        request.respond("Missing movie_id or episode_id", .{ .status = .bad_request }) catch return;
        return;
    }

    request.respond("OK", .{ .status = .ok }) catch return;
}
