const std = @import("std");
const db_mod = @import("../../db/db.zig");
const logging_mod = @import("../../db/logging.zig");
const utils = @import("../utils.zig");

const WatchEventPayload = struct {
    id: ?i64 = null,
    movie_id: ?i64 = null,
    episode_id: ?i64 = null,
    event: []const u8,
    position: f64,
    duration: f64,
};

pub fn handleApiWatchEvent(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, username: []const u8, body_buf: *[8192]u8) !void {
    const body_data = utils.readRequestBody(request, allocator, body_buf) catch {
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(WatchEventPayload, allocator, body_data, .{
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
        try logging_mod.logPlaybackEvent(database, username, movie_id, payload.event, payload.position);
        try logging_mod.savePlaybackProgress(database, username, movie_id, payload.position, payload.duration);
    } else if (payload.episode_id) |episode_id| {
        try logging_mod.logEpisodePlaybackEvent(database, username, episode_id, payload.event, payload.position);
        try logging_mod.saveEpisodePlaybackProgress(database, username, episode_id, payload.position, payload.duration);
    } else {
        request.respond("Missing movie_id or episode_id", .{ .status = .bad_request }) catch return;
        return;
    }

    request.respond("OK", .{ .status = .ok }) catch return;
}
