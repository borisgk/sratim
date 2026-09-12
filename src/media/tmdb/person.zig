const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");

pub fn fetchPersonDetails(
    allocator: std.mem.Allocator,
    io: std.Io,
    person_id: i64,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(types.TmdbPersonDetails) {
    _ = io;

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    const fetch_url = try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/person/{d}?append_to_response=movie_credits", .{person_id});
    defer allocator.free(fetch_url);

    std.debug.print("TMDB Person Details Request URL: {s}\n", .{fetch_url});

    var response = try client.get(fetch_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB Person Details Response Status: {d}\n", .{response.status.code});

    if (response.status.code == 404) {
        return error.NotFound;
    }

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    const response_body = response.body orelse return error.EmptyResponseBody;

    return try std.json.parseFromSlice(types.TmdbPersonDetails, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub const FilmographyItem = struct {
    id: i64,
    title: []const u8,
    release_date: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    role: ?[]const u8 = null,
};

fn compareFilmography(context: void, a: FilmographyItem, b: FilmographyItem) bool {
    _ = context;
    const a_date = a.release_date orelse "";
    const b_date = b.release_date orelse "";
    return std.mem.order(u8, a_date, b_date) == .gt;
}

pub fn buildFilmographyJson(allocator: std.mem.Allocator, credits: types.TmdbPersonMovieCredits) ![]u8 {
    var items = std.ArrayList(FilmographyItem).empty;
    defer items.deinit(allocator);

    var seen_ids = std.AutoHashMap(i64, usize).init(allocator);
    defer seen_ids.deinit();

    // Add cast
    for (credits.cast) |c| {
        if (c.title.len == 0) continue;
        if (!seen_ids.contains(c.id)) {
            try seen_ids.put(c.id, items.items.len);
            try items.append(allocator, .{
                .id = c.id,
                .title = c.title,
                .release_date = c.release_date,
                .poster_path = c.poster_path,
                .role = c.character,
            });
        }
    }

    // Add crew (e.g. Director, Writer, Producer)
    for (credits.crew) |cr| {
        if (cr.title.len == 0) continue;
        if (seen_ids.get(cr.id)) |existing_idx| {
            if (std.mem.eql(u8, cr.job, "Director")) {
                items.items[existing_idx].role = "Director";
            }
        } else {
            try seen_ids.put(cr.id, items.items.len);
            const r: ?[]const u8 = if (cr.job.len > 0) cr.job else if (cr.department.len > 0) cr.department else null;
            try items.append(allocator, .{
                .id = cr.id,
                .title = cr.title,
                .release_date = cr.release_date,
                .poster_path = cr.poster_path,
                .role = r,
            });
        }
    }

    std.mem.sort(FilmographyItem, items.items, {}, compareFilmography);

    return try std.json.Stringify.valueAlloc(allocator, items.items, .{});
}
