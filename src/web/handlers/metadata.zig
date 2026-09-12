const std = @import("std");
const config_mod = @import("../../config.zig");
const tmdb = @import("../../media/tmdb.zig");
const tmdb_client = @import("../../media/tmdb/client.zig");
const db_mod = @import("../../db/db.zig");
const metadata_mod = @import("../../db/metadata.zig");
const main = @import("../../main.zig");

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
    movie_id: ?i64 = null,
    show_id: ?i64 = null,
};

pub fn handleApiMetadataAutoLink(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, config: *const config_mod.Config, body_buf: *[8192]u8) !void {
    const token = config.getTmdbToken();
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

    // Fetch credits & profile pictures
    if (tmdb.fetchMovieCredits(allocator, io, first_movie.id, token, config.tmdb_proxy)) |credits_parsed| {
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
        metadata_mod.saveMovieCredits(database, movie_id, credits.cast, credits.crew) catch {};
    } else |_| {}

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

    // Fetch credits & profile pictures
    if (tmdb.fetchMovieCredits(allocator, io, movie.id, token, config.tmdb_proxy)) |credits_parsed| {
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
        metadata_mod.saveMovieCredits(database, movie_id, credits.cast, credits.crew) catch {};
    } else |_| {}

    request.respond("OK", .{ .status = .ok }) catch return;
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

pub fn handleApiPersonRefresh(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    resp_buf: *[8192]u8,
) !void {
    _ = resp_buf;
    const token = config.getTmdbToken();
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    var person_id_str: []const u8 = "";
    if (std.mem.indexOf(u8, request.head.target, "?")) |q_idx| {
        const params = request.head.target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, params, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "id=")) {
                person_id_str = param[3..];
            }
        }
    }

    if (person_id_str.len == 0) {
        request.respond("Missing id parameter", .{ .status = .bad_request }) catch return;
        return;
    }

    const person_id = std.fmt.parseInt(i64, person_id_str, 10) catch {
        request.respond("Invalid id parameter", .{ .status = .bad_request }) catch return;
        return;
    };

    const person_opt = metadata_mod.getPersonById(database, allocator, person_id) catch null;
    if (person_opt == null) {
        request.respond("Person not found", .{ .status = .not_found }) catch return;
        return;
    }
    var person = person_opt.?;
    defer person.deinit(allocator);

    if (tmdb.fetchPersonDetails(allocator, io, person.id, token, config.tmdb_proxy)) |details_parsed| {
        defer details_parsed.deinit();
        const d = details_parsed.value;

        var filmography_json: ?[]const u8 = null;
        defer if (filmography_json) |fj| allocator.free(fj);

        if (d.movie_credits) |credits| {
            filmography_json = tmdb.buildFilmographyJson(allocator, credits) catch null;
        }

        metadata_mod.savePersonDetails(
            database,
            person.id,
            d.biography,
            d.birthday,
            d.deathday,
            d.place_of_birth,
            d.imdb_id,
            filmography_json,
        ) catch |err| {
            std.debug.print("API Person Refresh error saving details: {}\n", .{err});
            request.respond("Failed to save person details", .{ .status = .internal_server_error }) catch return;
            return;
        };

        if (d.profile_path) |prof| {
            metadata_mod.updatePersonProfilePath(database, person.id, prof) catch {};
            tmdb.downloadProfileImage(allocator, io, prof, config.tmdb_proxy) catch {};
        } else if (person.profile_path) |prof| {
            tmdb.downloadProfileImage(allocator, io, prof, config.tmdb_proxy) catch {};
        }
    } else |err| {
        std.debug.print("API Person Refresh fetch error: {}\n", .{err});
        metadata_mod.markPersonDetailsFetched(database, person.id);
    }

    var headers_buf: [2]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    request.respond("{\"success\":true}", .{ .extra_headers = &headers_buf, .status = .ok }) catch return;
}

pub fn handleApiImageCache(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
) !void {
    var raw_path: []const u8 = "";
    if (std.mem.indexOf(u8, request.head.target, "?")) |q_idx| {
        const params = request.head.target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, params, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "path=")) {
                raw_path = param[5..];
            }
        }
    }

    if (raw_path.len == 0) {
        request.respond("Missing path parameter", .{ .status = .bad_request }) catch return;
        return;
    }

    const decoded = try allocator.dupe(u8, raw_path);
    defer allocator.free(decoded);
    const path = std.Uri.percentDecodeInPlace(decoded);

    // Disallow path traversal
    if (std.mem.indexOf(u8, path, "..") != null) {
        request.respond("Invalid path", .{ .status = .bad_request }) catch return;
        return;
    }

    var clean = path;
    if (std.mem.startsWith(u8, clean, "/")) clean = clean[1..];
    if (std.mem.startsWith(u8, clean, "images/")) clean = clean[7..];

    // If it's a direct profile filename without directories (e.g. "abc.jpg")
    if (std.mem.indexOfScalar(u8, clean, '/') == null) {
        const p = try std.fmt.allocPrint(allocator, "/{s}", .{clean});
        defer allocator.free(p);
        tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch |err| {
            std.debug.print("handleApiImageCache downloadProfileImage error: {}\n", .{err});
        };
    } else if (std.mem.startsWith(u8, clean, "profiles/w185/")) {
        const p = clean["profiles/w185".len..];
        tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch |err| {
            std.debug.print("handleApiImageCache downloadProfileImage error: {}\n", .{err});
        };
    } else {
        // Format: {category}/{size}/{filename}, e.g. "posters/w500/abc.jpg"
        if (std.mem.indexOfScalar(u8, clean, '/')) |slash_idx| {
            const tmdb_subpath = clean[slash_idx + 1 ..];
            const dest_file = try std.fmt.allocPrint(allocator, "images/{s}", .{clean});
            defer allocator.free(dest_file);

            if (main.app_dir.statFile(io, dest_file, .{})) |_| {
                // Already cached
            } else |_| {
                const tmdb_url = try std.fmt.allocPrint(allocator, "https://image.tmdb.org/t/p/{s}", .{tmdb_subpath});
                defer allocator.free(tmdb_url);

                if (tmdb_client.createClient(allocator, config.tmdb_proxy)) |*client_val| {
                    var client = client_val.*;
                    defer client.deinit();

                    if (client.get(tmdb_url, .{})) |response| {
                        var res = response;
                        defer res.deinit();
                        if (res.status.isSuccess() and res.body != null) {
                            if (std.mem.lastIndexOfScalar(u8, dest_file, '/')) |last_slash| {
                                main.app_dir.createDirPath(io, dest_file[0..last_slash]) catch {};
                            }
                            main.app_dir.writeFile(io, .{ .sub_path = dest_file, .data = res.body.? }) catch {};
                        }
                    } else |_| {}
                } else |_| {}
            }
        }
    }

    var headers_buf: [2]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    request.respond("{\"success\":true}", .{ .extra_headers = &headers_buf, .status = .ok }) catch return;
}


