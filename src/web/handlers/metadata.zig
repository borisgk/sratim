const std = @import("std");
const config_mod = @import("../../config.zig");
const tmdb = @import("../../media/tmdb.zig");
const db_mod = @import("../../db/db.zig");
const metadata_mod = @import("../../db/metadata.zig");

pub fn handleApiMetadataSearch(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, config: *const config_mod.Config) !void {
    const token = config.tmdb_access_token orelse {
        request.respond("TMDB Access Token not configured in config.json", .{ .status = .bad_request }) catch return;
        return;
    };
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
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    const parsed = std.json.parseFromSlice(MetadataLinkPayload, allocator, body_data.items, .{
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

    request.respond("OK", .{ .status = .ok }) catch return;
}

const MetadataAutoLinkPayload = struct {
    movie_id: i64,
};

pub fn handleApiMetadataAutoLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    const token = config.tmdb_access_token orelse {
        request.respond("TMDB Access Token not configured in config.json", .{ .status = .bad_request }) catch return;
        return;
    };
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    const parsed = std.json.parseFromSlice(MetadataAutoLinkPayload, allocator, body_data.items, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.debug.print("Failed to parse metadata auto-link JSON: {any}\n", .{err});
        request.respond("Bad Request", .{ .status = .bad_request }) catch return;
        return;
    };
    defer parsed.deinit();

    const payload = parsed.value;

    const info_opt = try metadata_mod.getMovieInfoById(database, allocator, payload.movie_id);
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
        payload.movie_id,
        first_movie.id,
        first_movie.title,
        first_movie.overview,
        first_movie.poster_path,
        first_movie.backdrop_path,
        first_movie.release_date,
    );

    request.respond("OK", .{ .status = .ok }) catch return;
}

const MetadataManualLinkPayload = struct {
    movie_id: i64,
    tmdb_id: i64,
};

pub fn handleApiMetadataManualLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    const token = config.tmdb_access_token orelse {
        request.respond("TMDB Access Token not configured in config.json", .{ .status = .bad_request }) catch return;
        return;
    };
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    const parsed = std.json.parseFromSlice(MetadataManualLinkPayload, allocator, body_data.items, .{
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
        payload.movie_id,
        movie.id,
        movie.title,
        movie.overview,
        movie.poster_path,
        movie.backdrop_path,
        movie.release_date,
    );

    request.respond("OK", .{ .status = .ok }) catch return;
}

