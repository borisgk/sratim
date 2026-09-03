const std = @import("std");
const db_mod = @import("db.zig");

pub const MovieMetadata = struct {
    movie_id: i64,
    library_id: i64,
    file_path: []const u8,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    release_date: ?[]const u8,
};

pub const MovieInfo = struct {
    library_id: i64,
    file_path: []const u8,
};

pub const MovieMissingMetadata = struct {
    id: i64,
    clean_name: []const u8,
};

pub const EpisodeMissingMetadata = struct {
    id: i64,
    show_tmdb_id: i64,
    season: i64,
    episode: i64,
};

pub fn getMovieInfoById(database: *db_mod.Database, allocator: std.mem.Allocator, movie_id: i64) !?MovieInfo {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const mov = (try cat.getMovieById(allocator, movie_id)) orelse return null;
    defer {
        var m = mov;
        m.deinit(allocator);
    }
    return MovieInfo{
        .library_id = mov.library_id,
        .file_path = try allocator.dupe(u8, mov.file_path),
    };
}

pub fn getEpisodeInfoById(database: *db_mod.Database, allocator: std.mem.Allocator, episode_id: i64) !?MovieInfo {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.rwlock.lockSharedUncancelable(cat.io);
    defer cat.rwlock.unlockShared(cat.io);

    const ep = cat.episodes.get(episode_id) orelse return null;
    const show = cat.shows.get(ep.show_id) orelse return null;

    return MovieInfo{
        .library_id = show.library_id,
        .file_path = try allocator.dupe(u8, ep.file_path),
    };
}

pub fn getShowTitleById(database: *db_mod.Database, allocator: std.mem.Allocator, show_id: i64) !?[]const u8 {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const show = (try cat.getShowById(allocator, show_id)) orelse return null;
    defer {
        var s = show;
        s.deinit(allocator);
    }
    return try allocator.dupe(u8, show.title);
}

pub fn getMoviesMissingMetadata(database: *db_mod.Database, allocator: std.mem.Allocator) ![]MovieMissingMetadata {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const movies = try cat.getMoviesMissingMetadata(allocator);
    defer {
        for (movies) |*m| {
            var mut = m.*;
            mut.deinit(allocator);
        }
        allocator.free(movies);
    }

    var list = std.ArrayList(MovieMissingMetadata).empty;
    errdefer {
        for (list.items) |item| allocator.free(item.clean_name);
        list.deinit(allocator);
    }

    for (movies) |m| {
        try list.append(allocator, .{
            .id = m.id,
            .clean_name = try allocator.dupe(u8, m.clean_name),
        });
    }
    return try list.toOwnedSlice(allocator);
}

pub fn getShowsMissingMetadata(database: *db_mod.Database, allocator: std.mem.Allocator) ![]MovieMissingMetadata {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const shows = try cat.getShowsMissingMetadata(allocator);
    defer {
        for (shows) |*s| {
            var mut = s.*;
            mut.deinit(allocator);
        }
        allocator.free(shows);
    }

    var list = std.ArrayList(MovieMissingMetadata).empty;
    errdefer {
        for (list.items) |item| allocator.free(item.clean_name);
        list.deinit(allocator);
    }

    for (shows) |s| {
        try list.append(allocator, .{
            .id = s.id,
            .clean_name = try allocator.dupe(u8, s.title),
        });
    }
    return try list.toOwnedSlice(allocator);
}

pub fn getEpisodesMissingMetadata(database: *db_mod.Database, allocator: std.mem.Allocator) ![]EpisodeMissingMetadata {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.rwlock.lockSharedUncancelable(cat.io);
    defer cat.rwlock.unlockShared(cat.io);

    var list = std.ArrayList(EpisodeMissingMetadata).empty;
    errdefer list.deinit(allocator);

    var it = cat.episodes.iterator();
    while (it.next()) |e| {
        if (!e.value_ptr.is_present) continue;
        if (e.value_ptr.tmdb_id != null) continue;

        if (cat.shows.get(e.value_ptr.show_id)) |sh| {
            if (sh.tmdb_id != null and sh.tmdb_id.? > 0) {
                try list.append(allocator, .{
                    .id = e.key_ptr.*,
                    .show_tmdb_id = sh.tmdb_id.?,
                    .season = e.value_ptr.season,
                    .episode = e.value_ptr.episode,
                });
            }
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn saveMetadataById(
    database: *db_mod.Database,
    movie_id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    release_date: ?[]const u8,
) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    try cat.linkMovieMetadata(movie_id, tmdb_id, title, overview, poster_path, backdrop_path, release_date);
    cat.snapshot() catch {};
}

pub fn saveShowMetadataById(
    database: *db_mod.Database,
    show_id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    poster_path: ?[]const u8,
    backdrop_path: ?[]const u8,
    first_air_date: ?[]const u8,
) !void {
    _ = first_air_date;
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    try cat.linkShowMetadata(show_id, tmdb_id, title, overview, poster_path, backdrop_path);
    cat.snapshot() catch {};
}

pub fn saveEpisodeMetadataById(
    database: *db_mod.Database,
    episode_id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8,
    still_path: ?[]const u8,
) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    try cat.linkEpisodeMetadata(episode_id, tmdb_id, title, overview, still_path);
    cat.snapshot() catch {};
}

pub fn getMetadataById(
    database: *db_mod.Database,
    allocator: std.mem.Allocator,
    movie_id: i64,
) !?MovieMetadata {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    const mov = (try cat.getMovieById(allocator, movie_id)) orelse return null;
    defer {
        var m = mov;
        m.deinit(allocator);
    }
    if (mov.tmdb_id == null or mov.tmdb_id.? <= 0) return null;

    return MovieMetadata{
        .movie_id = movie_id,
        .library_id = mov.library_id,
        .file_path = try allocator.dupe(u8, mov.file_path),
        .tmdb_id = mov.tmdb_id.?,
        .title = try allocator.dupe(u8, mov.title orelse mov.clean_name),
        .overview = if (mov.overview) |o| try allocator.dupe(u8, o) else null,
        .poster_path = if (mov.poster_path) |p| try allocator.dupe(u8, p) else null,
        .backdrop_path = if (mov.backdrop_path) |b| try allocator.dupe(u8, b) else null,
        .release_date = if (mov.release_date) |r| try allocator.dupe(u8, r) else null,
    };
}

pub fn markEpisodeMetadataNotFound(database: *db_mod.Database, episode_id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    {
        cat.rwlock.lockUncancelable(cat.io);
        defer cat.rwlock.unlock(cat.io);

        if (cat.episodes.getPtr(episode_id)) |ptr| {
            ptr.tmdb_id = 0;
        }
    }
    cat.snapshot() catch {};
}

pub fn deleteMetadataById(database: *db_mod.Database, movie_id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    try cat.unlinkMovieMetadata(movie_id);
    cat.snapshot() catch {};
}

pub fn markMetadataNotFound(database: *db_mod.Database, movie_id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    {
        cat.rwlock.lockUncancelable(cat.io);
        defer cat.rwlock.unlock(cat.io);

        if (cat.movies.getPtr(movie_id)) |ptr| {
            ptr.tmdb_id = 0;
        }
    }
    cat.snapshot() catch {};
}

pub fn markShowMetadataNotFound(database: *db_mod.Database, show_id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    {
        cat.rwlock.lockUncancelable(cat.io);
        defer cat.rwlock.unlock(cat.io);

        if (cat.shows.getPtr(show_id)) |ptr| {
            ptr.tmdb_id = 0;
        }
    }
    cat.snapshot() catch {};
}

pub fn resetShowEpisodesMetadata(database: *db_mod.Database, show_id: i64) !void {
    const cat = database.catalog orelse return error.CatalogNotConfigured;
    cat.rwlock.lockUncancelable(cat.io);
    defer cat.rwlock.unlock(cat.io);

    var it = cat.episodes.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.show_id == show_id) {
            e.value_ptr.tmdb_id = null;
            if (e.value_ptr.title) |t| cat.allocator.free(t);
            e.value_ptr.title = null;
            if (e.value_ptr.overview) |o| cat.allocator.free(o);
            e.value_ptr.overview = null;
            if (e.value_ptr.still_path) |s| cat.allocator.free(s);
            e.value_ptr.still_path = null;
        }
    }
}
