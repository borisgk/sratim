const std = @import("std");
const config_mod = @import("../../../config.zig");
const tmdb = @import("../../../media/tmdb.zig");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");

pub fn syncShowCredits(
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    show_id: i64,
    tmdb_id: i64,
    token: []const u8,
) !usize {
    var credits_parsed = try tmdb.fetchShowCredits(allocator, io, tmdb_id, token, config.tmdb_proxy);
    defer credits_parsed.deinit();

    const credits = credits_parsed.value;
    const cast_limit = @min(credits.cast.len, 20);
    for (credits.cast[0..cast_limit]) |c| {
        if (c.profile_path) |p| {
            tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch {};
        }
    }
    for (credits.crew) |cr| {
        if (std.mem.eql(u8, cr.job, "Director") or
            std.mem.eql(u8, cr.job, "Creator") or
            std.mem.eql(u8, cr.job, "Created by") or
            std.mem.eql(u8, cr.job, "Series Director"))
        {
            if (cr.profile_path) |p| {
                tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch {};
            }
        }
    }
    try metadata_mod.saveShowCredits(database, show_id, credits.cast, credits.crew);
    return cast_limit;
}

pub fn syncMovieCredits(
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    movie_id: i64,
    tmdb_id: i64,
    token: []const u8,
) !usize {
    var credits_parsed = try tmdb.fetchMovieCredits(allocator, io, tmdb_id, token, config.tmdb_proxy);
    defer credits_parsed.deinit();

    const credits = credits_parsed.value;
    const cast_limit = @min(credits.cast.len, 20);
    for (credits.cast[0..cast_limit]) |c| {
        if (c.profile_path) |p| {
            tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch {};
        }
    }
    for (credits.crew) |cr| {
        if (std.mem.eql(u8, cr.job, "Director")) {
            if (cr.profile_path) |p| {
                tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch {};
            }
        }
    }
    try metadata_mod.saveMovieCredits(database, movie_id, credits.cast, credits.crew);
    return cast_limit;
}
