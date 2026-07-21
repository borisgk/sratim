const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");

pub fn searchMovie(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    year: ?[]const u8,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(types.TmdbSearchResponse) {
    _ = io;

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    var query_encoded = std.ArrayList(u8).empty;
    defer query_encoded.deinit(allocator);
    try client_mod.writePercentEncoded(&query_encoded, allocator, query);

    const search_url = if (year) |y|
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}&primary_release_year={s}", .{ query_encoded.items, y })
    else
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}", .{query_encoded.items});
    defer allocator.free(search_url);

    std.debug.print("TMDB Request URL: {s}\n", .{search_url});
    if (proxy_url) |p| {
        if (p.len > 0) {
            std.debug.print("TMDB Request Proxy: {s}\n", .{p});
        }
    }

    var response = try client.get(search_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB Response Status: {d}\n", .{response.status.code});
    const response_body = response.body orelse return error.EmptyResponseBody;
    std.debug.print("TMDB Response Body: {s}\n", .{response_body});

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    return try std.json.parseFromSlice(types.TmdbSearchResponse, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn fetchMovieDetails(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmdb_id: i64,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(types.TmdbMovie) {
    _ = io;

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    const fetch_url = try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/movie/{d}", .{tmdb_id});
    defer allocator.free(fetch_url);

    std.debug.print("TMDB Movie Details Request URL: {s}\n", .{fetch_url});

    var response = try client.get(fetch_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB Movie Details Response Status: {d}\n", .{response.status.code});

    if (response.status.code == 404) {
        return error.NotFound;
    }

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    const response_body = response.body orelse return error.EmptyResponseBody;

    return try std.json.parseFromSlice(types.TmdbMovie, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}
