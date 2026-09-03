const std = @import("std");
const db_mod = @import("db.zig");

pub const ProgressInfo = struct {
    movie_id: i64,
    position: f64,
    duration: f64,
};

pub const EpisodeProgressInfo = struct {
    episode_id: i64,
    position: f64,
    duration: f64,
};

pub const RecentlyWatchedItem = struct {
    media_type: enum { movie, episode },
    item_id: i64,
    position: f64,
    duration: f64,
    updated_at: i64,
};

/// Initializes the logging and progress database schema (no-op in pure Zig memory storage).
pub fn initLogsSchema(database: *db_mod.Database) !void {
    _ = database;
}

/// Logs a user authentication attempt (success or failure).
pub fn logLoginAttempt(database: *db_mod.Database, username: []const u8, status: []const u8, ip_address: []const u8) !void {
    const logs = database.logs orelse return error.LogsNotConfigured;
    try logs.logLoginAttempt(username, status, ip_address);
}

/// Logs a specific playback watch event.
pub fn logPlaybackEvent(database: *db_mod.Database, username: []const u8, movie_id: i64, event_type: []const u8, position: f64) !void {
    const logs = database.logs orelse return error.LogsNotConfigured;
    try logs.logPlaybackEvent(username, movie_id, event_type, position);
}

/// Saves the user's current playback position progress for a media file.
pub fn savePlaybackProgress(database: *db_mod.Database, username: []const u8, movie_id: i64, position: f64, duration: f64) !void {
    const logs = database.logs orelse return error.LogsNotConfigured;
    try logs.savePlaybackProgress(username, movie_id, position, duration);
}

/// Retrieves the user's last saved playback position for a specific media file.
pub fn getPlaybackProgress(database: *db_mod.Database, username: []const u8, movie_id: i64) !f64 {
    const logs = database.logs orelse return error.LogsNotConfigured;
    return logs.getPlaybackProgress(username, movie_id);
}

/// Retrieves all playback progress records for a given user.
pub fn getProgressForUser(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8) ![]ProgressInfo {
    const logs = database.logs orelse return error.LogsNotConfigured;
    const raw = try logs.getProgressForUser(allocator, username);
    defer {
        for (raw) |*p| {
            var mut = p.*;
            mut.deinit(allocator);
        }
        allocator.free(raw);
    }

    var list = try allocator.alloc(ProgressInfo, raw.len);
    for (raw, 0..) |p, i| {
        list[i] = .{
            .movie_id = p.movie_id,
            .position = p.position,
            .duration = p.duration,
        };
    }
    return list;
}

/// Resets the user's playback position to 0 for a media file.
pub fn resetPlaybackProgress(database: *db_mod.Database, username: []const u8, movie_id: i64) !void {
    const logs = database.logs orelse return error.LogsNotConfigured;
    logs.deletePlaybackProgress(username, movie_id);
}

/// Logs a specific episode playback watch event.
pub fn logEpisodePlaybackEvent(database: *db_mod.Database, username: []const u8, episode_id: i64, event_type: []const u8, position: f64) !void {
    const logs = database.logs orelse return error.LogsNotConfigured;
    try logs.logEpisodePlaybackEvent(username, episode_id, event_type, position);
}

/// Saves the user's current playback position progress for an episode.
pub fn saveEpisodePlaybackProgress(database: *db_mod.Database, username: []const u8, episode_id: i64, position: f64, duration: f64) !void {
    const logs = database.logs orelse return error.LogsNotConfigured;
    try logs.saveEpisodePlaybackProgress(username, episode_id, position, duration);
}

/// Retrieves the user's last saved playback position for a specific episode.
pub fn getEpisodePlaybackProgress(database: *db_mod.Database, username: []const u8, episode_id: i64) !f64 {
    const logs = database.logs orelse return error.LogsNotConfigured;
    return logs.getEpisodePlaybackProgress(username, episode_id);
}

/// Retrieves all episode playback progress records for a given user.
pub fn getEpisodeProgressForUser(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8) ![]EpisodeProgressInfo {
    const logs = database.logs orelse return error.LogsNotConfigured;
    const raw = try logs.getEpisodeProgressForUser(allocator, username);
    defer {
        for (raw) |*p| {
            var mut = p.*;
            mut.deinit(allocator);
        }
        allocator.free(raw);
    }

    var list = try allocator.alloc(EpisodeProgressInfo, raw.len);
    for (raw, 0..) |p, i| {
        list[i] = .{
            .episode_id = p.episode_id,
            .position = p.position,
            .duration = p.duration,
        };
    }
    return list;
}

/// Resets the user's playback position to 0 for an episode.
pub fn resetEpisodePlaybackProgress(database: *db_mod.Database, username: []const u8, episode_id: i64) !void {
    const logs = database.logs orelse return error.LogsNotConfigured;
    logs.deleteEpisodePlaybackProgress(username, episode_id);
}

/// Retrieves recently watched movies and episodes for a given user, ordered by most recently updated.
pub fn getRecentlyWatched(database: *db_mod.Database, allocator: std.mem.Allocator, username: []const u8, limit: usize) ![]RecentlyWatchedItem {
    const logs = database.logs orelse return error.LogsNotConfigured;
    const items = try logs.getRecentlyWatched(allocator, username, limit);
    defer allocator.free(items);

    var list = try allocator.alloc(RecentlyWatchedItem, items.len);
    for (items, 0..) |item, i| {
        list[i] = .{
            .media_type = if (item.media_type == .movie) .movie else .episode,
            .item_id = item.item_id,
            .position = item.position,
            .duration = item.duration,
            .updated_at = item.updated_at,
        };
    }
    return list;
}
