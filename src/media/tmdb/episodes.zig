const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");

pub fn fetchEpisode(
    allocator: std.mem.Allocator,
    io: std.Io,
    show_tmdb_id: i64,
    season: i64,
    episode: i64,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(types.TmdbEpisode) {
    _ = io;

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    const fetch_url = try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/tv/{d}/season/{d}/episode/{d}", .{ show_tmdb_id, season, episode });
    defer allocator.free(fetch_url);

    std.debug.print("TMDB TV Episode Request URL: {s}\n", .{fetch_url});

    var response = try client.get(fetch_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB TV Episode Response Status: {d}\n", .{response.status.code});
    const response_body = response.body orelse return error.EmptyResponseBody;

    if (response.status.code == 404) {
        return error.NotFound;
    }

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    return try std.json.parseFromSlice(types.TmdbEpisode, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}
