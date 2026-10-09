const std = @import("std");
const config_mod = @import("../../config.zig");
const tmdb = @import("../../media/tmdb.zig");
const db_mod = @import("../../db/db.zig");
const metadata_mod = @import("../../db/metadata.zig");
const utils = @import("../utils.zig");


pub const credits_sync = @import("metadata/credits_sync.zig");
pub const syncShowCredits = credits_sync.syncShowCredits;
pub const syncMovieCredits = credits_sync.syncMovieCredits;

pub const image_cache = @import("metadata/image_cache.zig");
pub const handleApiImageCache = image_cache.handleApiImageCache;

pub const person = @import("metadata/person.zig");
pub const handleApiPersonRefresh = person.handleApiPersonRefresh;

pub fn handleApiMetadataSearch(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, config: *const config_mod.Config) !void {
    const token = config.getTmdbToken();
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    var query: []const u8 = "";
    if (std.mem.indexOf(u8, request.head.target, "?")) |q_idx| {
        const params = request.head.target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, params, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "query=")) {
                query = param[6..];
            }
        }
    }

    if (query.len == 0) {
        request.respond("Missing query parameter", .{ .status = .bad_request }) catch return;
        return;
    }

    // Percent decode query
    const decoded_query = try allocator.dupe(u8, query);
    defer allocator.free(decoded_query);
    const clean_query = std.Uri.percentDecodeInPlace(decoded_query);

    const parsed_name = try tmdb.parseYearAndCleanName(allocator, clean_query);
    defer allocator.free(parsed_name.clean);
    defer if (parsed_name.year) |y| allocator.free(y);

    var response_parsed = tmdb.searchMovie(allocator, io, parsed_name.clean, parsed_name.year, token, config.tmdb_proxy) catch |err| {
        std.debug.print("TMDB Search error: {}\n", .{err});
        request.respond("TMDB API request failed", .{ .status = .internal_server_error }) catch return;
        return;
    };
    defer response_parsed.deinit();

    // Stringify the results array
    var response_allocating = std.Io.Writer.Allocating.init(allocator);
    defer response_allocating.deinit();
    try std.json.Stringify.value(response_parsed.value.results, .{}, &response_allocating.writer);

    request.respond(response_allocating.written(), .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return;
}

const MetadataLinkPayload = struct {
    movie_id: i64,
    tmdb_id: i64,
    title: []const u8,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    backdrop_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
};

pub fn handleApiMetadataLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    const body_data = utils.readRequestBody(request, allocator, body_buf) catch {
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(MetadataLinkPayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse metadata link JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    // Download images locally before saving metadata
    tmdb.downloadImages(allocator, io, payload.poster_path, payload.backdrop_path, config.tmdb_proxy) catch |err| {
        std.debug.print("Failed to download images: {}\n", .{err});
    };

    try metadata_mod.saveMetadataById(
        database,
        payload.movie_id,
        payload.tmdb_id,
        payload.title,
        payload.overview,
        payload.poster_path,
        payload.backdrop_path,
        payload.release_date,
    );

    const token = config.getTmdbToken();
    if (token.len > 0) {
        _ = syncMovieCredits(allocator, io, database, config, payload.movie_id, payload.tmdb_id, token) catch {};
    }

    request.respond("OK", .{ .status = .ok }) catch return;
}

const MetadataAutoLinkPayload = struct {
    movie_id: ?i64 = null,
    show_id: ?i64 = null,
};

pub fn handleApiMetadataAutoLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    const token = config.getTmdbToken();
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    const body_data = utils.readRequestBody(request, allocator, body_buf) catch {
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(MetadataAutoLinkPayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse metadata auto-link JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    if (payload.show_id) |show_id| {
        const title_opt = try metadata_mod.getShowTitleById(database, allocator, show_id);
        if (title_opt == null) {
            request.respond("Show not found", .{ .status = .not_found }) catch return;
            return;
        }
        const show_title = title_opt.?;
        defer allocator.free(show_title);

        const parsed_name = try tmdb.parseYearAndCleanName(allocator, show_title);
        defer allocator.free(parsed_name.clean);
        defer if (parsed_name.year) |y| allocator.free(y);

        var response_parsed = tmdb.searchShow(allocator, io, parsed_name.clean, parsed_name.year, token, config.tmdb_proxy) catch |err| {
            std.debug.print("TMDB Auto Search Show error: {}\n", .{err});
            request.respond("TMDB API request failed", .{ .status = .internal_server_error }) catch return;
            return;
        };
        defer response_parsed.deinit();

        if (response_parsed.value.results.len == 0) {
            request.respond("No metadata found for this show name.", .{ .status = .not_found }) catch return;
            return;
        }

        const first_show = response_parsed.value.results[0];

        tmdb.downloadImages(allocator, io, first_show.poster_path, first_show.backdrop_path, config.tmdb_proxy) catch |err| {
            std.debug.print("Failed to download images: {}\n", .{err});
        };

        try metadata_mod.saveShowMetadataById(
            database,
            show_id,
            first_show.id,
            first_show.name,
            first_show.overview,
            first_show.poster_path,
            first_show.backdrop_path,
            first_show.first_air_date,
        );

        try metadata_mod.resetShowEpisodesMetadata(database, show_id);

        _ = syncShowCredits(allocator, io, database, config, show_id, first_show.id, token) catch {};

        request.respond("OK", .{ .status = .ok }) catch return;
        return;
    }

    const movie_id = payload.movie_id orelse {
        request.respond("Missing movie_id or show_id", .{ .status = .bad_request }) catch return;
        return;
    };

    const info_opt = try metadata_mod.getMovieInfoById(database, allocator, movie_id);
    if (info_opt == null) {
        request.respond("Movie not found", .{ .status = .not_found }) catch return;
        return;
    }
    const info = info_opt.?;
    defer allocator.free(info.file_path);

    // Get clean name from file path
    const basename = std.fs.path.basename(info.file_path);
    const ext = std.fs.path.extension(basename);
    const clean_name = basename[0 .. basename.len - ext.len];

    const parsed_name = try tmdb.parseYearAndCleanName(allocator, clean_name);
    defer allocator.free(parsed_name.clean);
    defer if (parsed_name.year) |y| allocator.free(y);

    // Search TMDB
    var response_parsed = tmdb.searchMovie(allocator, io, parsed_name.clean, parsed_name.year, token, config.tmdb_proxy) catch |err| {
        std.debug.print("TMDB Auto Search error: {}\n", .{err});
        request.respond("TMDB API request failed", .{ .status = .internal_server_error }) catch return;
        return;
    };
    defer response_parsed.deinit();

    if (response_parsed.value.results.len == 0) {
        request.respond("No metadata found for this movie name.", .{ .status = .not_found }) catch return;
        return;
    }

    const first_movie = response_parsed.value.results[0];

    // Download images locally before saving metadata
    tmdb.downloadImages(allocator, io, first_movie.poster_path, first_movie.backdrop_path, config.tmdb_proxy) catch |err| {
        std.debug.print("Failed to download images: {}\n", .{err});
    };

    try metadata_mod.saveMetadataById(
        database,
        movie_id,
        first_movie.id,
        first_movie.title,
        first_movie.overview,
        first_movie.poster_path,
        first_movie.backdrop_path,
        first_movie.release_date,
    );

    _ = syncMovieCredits(allocator, io, database, config, movie_id, first_movie.id, token) catch {};

    request.respond("OK", .{ .status = .ok }) catch return;
}

const MetadataManualLinkPayload = struct {
    movie_id: ?i64 = null,
    show_id: ?i64 = null,
    tmdb_id: i64,
};

pub fn handleApiMetadataManualLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    const token = config.getTmdbToken();
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    const body_data = utils.readRequestBodyWithLimit(request, allocator, body_buf, 1024 * 1024) catch {
        request.respond("Payload Too Large", .{ .status = .payload_too_large }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(MetadataManualLinkPayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse metadata manual link JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    if (payload.tmdb_id <= 0) {
        request.respond("Invalid TMDB ID", .{ .status = .bad_request }) catch return;
        return;
    }

    if (payload.show_id) |show_id| {
        var parsed_show = tmdb.fetchShowDetails(allocator, io, payload.tmdb_id, token, config.tmdb_proxy) catch |err| {
            std.debug.print("TMDB Fetch Show Details error: {}\n", .{err});
            if (err == error.NotFound) {
                request.respond("TMDB Show ID not found", .{ .status = .not_found }) catch return;
            } else {
                request.respond("TMDB API request failed", .{ .status = .internal_server_error }) catch return;
            }
            return;
        };
        defer parsed_show.deinit();

        const show = parsed_show.value;

        tmdb.downloadImages(allocator, io, show.poster_path, show.backdrop_path, config.tmdb_proxy) catch |err| {
            std.debug.print("Failed to download images: {}\n", .{err});
        };

        try metadata_mod.saveShowMetadataById(
            database,
            show_id,
            show.id,
            show.name,
            show.overview,
            show.poster_path,
            show.backdrop_path,
            show.first_air_date,
        );

        try metadata_mod.resetShowEpisodesMetadata(database, show_id);

        _ = syncShowCredits(allocator, io, database, config, show_id, show.id, token) catch {};

        request.respond("OK", .{ .status = .ok }) catch return;
        return;
    }

    const movie_id = payload.movie_id orelse {
        request.respond("Missing movie_id or show_id", .{ .status = .bad_request }) catch return;
        return;
    };

    var parsed_movie = tmdb.fetchMovieDetails(allocator, io, payload.tmdb_id, token, config.tmdb_proxy) catch |err| {
        std.debug.print("TMDB Fetch Movie Details error: {}\n", .{err});
        if (err == error.NotFound) {
            request.respond("TMDB Movie ID not found", .{ .status = .not_found }) catch return;
        } else {
            request.respond("TMDB API request failed", .{ .status = .internal_server_error }) catch return;
        }
        return;
    };
    defer parsed_movie.deinit();

    const movie = parsed_movie.value;

    tmdb.downloadImages(allocator, io, movie.poster_path, movie.backdrop_path, config.tmdb_proxy) catch |err| {
        std.debug.print("Failed to download images: {}\n", .{err});
    };

    try metadata_mod.saveMetadataById(
        database,
        movie_id,
        movie.id,
        movie.title,
        movie.overview,
        movie.poster_path,
        movie.backdrop_path,
        movie.release_date,
    );

    _ = syncMovieCredits(allocator, io, database, config, movie_id, movie.id, token) catch {};

    request.respond("OK", .{ .status = .ok }) catch return;
}

const MetadataRefetchCreditsPayload = struct {
    movie_id: ?i64 = null,
    show_id: ?i64 = null,
};

pub fn handleApiMetadataRefetchCredits(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    body_buf: *[8192]u8,
) !void {
    const token = config.getTmdbToken();
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    const body_data = utils.readRequestBodyWithLimit(request, allocator, body_buf, 1024 * 1024) catch {
        request.respond("Payload Too Large", .{ .status = .payload_too_large }) catch return;
        return;
    };
    defer allocator.free(body_data);

    const parsed = std.json.parseFromSlice(MetadataRefetchCreditsPayload, allocator, body_data, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse metadata refetch credits JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;
    const cat = database.catalog orelse {
        request.respond("Catalog not configured", .{ .status = .internal_server_error }) catch return;
        return;
    };

    if (payload.show_id) |show_id| {
        const show_opt = try cat.getShowById(allocator, show_id);
        if (show_opt == null) {
            request.respond("Show not found", .{ .status = .not_found }) catch return;
            return;
        }
        defer {
            var s = show_opt.?;
            s.deinit(allocator);
        }
        const s = show_opt.?;
        if (s.tmdb_id == null or s.tmdb_id.? <= 0) {
            request.respond("Show has no TMDB ID", .{ .status = .bad_request }) catch return;
            return;
        }

        const count = syncShowCredits(allocator, io, database, config, show_id, s.tmdb_id.?, token) catch |err| {
            std.debug.print("Failed to refetch show credits: {}\n", .{err});
            request.respond("Failed to fetch credits from TMDB", .{ .status = .internal_server_error }) catch return;
            return;
        };

        var res_buf: [128]u8 = undefined;
        const res_json = try std.fmt.bufPrint(&res_buf, "{{\"status\":\"ok\",\"cast_count\":{d}}}", .{count});
        request.respond(res_json, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch return;
        return;
    }

    if (payload.movie_id) |movie_id| {
        const movie_opt = try cat.getMovieById(allocator, movie_id);
        if (movie_opt == null) {
            request.respond("Movie not found", .{ .status = .not_found }) catch return;
            return;
        }
        defer {
            var m = movie_opt.?;
            m.deinit(allocator);
        }
        const m = movie_opt.?;
        if (m.tmdb_id == null or m.tmdb_id.? <= 0) {
            request.respond("Movie has no TMDB ID", .{ .status = .bad_request }) catch return;
            return;
        }

        const count = syncMovieCredits(allocator, io, database, config, movie_id, m.tmdb_id.?, token) catch |err| {
            std.debug.print("Failed to refetch movie credits: {}\n", .{err});
            request.respond("Failed to fetch credits from TMDB", .{ .status = .internal_server_error }) catch return;
            return;
        };

        var res_buf: [128]u8 = undefined;
        const res_json = try std.fmt.bufPrint(&res_buf, "{{\"status\":\"ok\",\"cast_count\":{d}}}", .{count});
        request.respond(res_json, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        }) catch return;
        return;
    }

    request.respond("Missing show_id or movie_id", .{ .status = .bad_request }) catch return;
}

pub fn handleApiMetadataSyncCredits(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    is_admin: bool,
) !void {
    if (!is_admin) {
        request.respond("Forbidden", .{ .status = .forbidden }) catch return;
        return;
    }

    const missing_credits = metadata_mod.getMoviesMissingCredits(database, allocator) catch {
        request.respond("Failed to query missing credits", .{ .status = .internal_server_error }) catch return;
        return;
    };
    const count = missing_credits.len;
    for (missing_credits) |*m| {
        var mut = m.*;
        mut.deinit(allocator);
    }
    allocator.free(missing_credits);

    var res_buf: [128]u8 = undefined;
    const json_res = std.fmt.bufPrint(&res_buf, "{{\"status\":\"ok\",\"pending\":{d}}}", .{count}) catch "{\"status\":\"ok\"}";

    var headers_buf: [2]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    request.respond(json_res, .{ .extra_headers = &headers_buf, .status = .ok }) catch return;
}
