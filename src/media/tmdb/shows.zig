const std = @import("std");
const types = @import("types.zig");
const client_mod = @import("client.zig");

pub fn searchShow(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    year: ?[]const u8,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(types.TmdbShowSearchResponse) {
    _ = io;

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    var query_encoded = std.ArrayList(u8).empty;
    defer query_encoded.deinit(allocator);
    try client_mod.writePercentEncoded(&query_encoded, allocator, query);

    const search_url = if (year) |y|
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/tv?query={s}&first_air_date_year={s}", .{ query_encoded.items, y })
    else
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/tv?query={s}", .{query_encoded.items});
    defer allocator.free(search_url);

    std.debug.print("TMDB TV Request URL: {s}\n", .{search_url});
    if (proxy_url) |p| {
        if (p.len > 0) {
            std.debug.print("TMDB TV Request Proxy: {s}\n", .{p});
        }
    }

    var response = try client.get(search_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB TV Response Status: {d}\n", .{response.status.code});
    const response_body = response.body orelse return error.EmptyResponseBody;
    std.debug.print("TMDB TV Response Body: {s}\n", .{response_body});

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    return try std.json.parseFromSlice(types.TmdbShowSearchResponse, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub fn fetchShowDetails(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmdb_id: i64,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(types.TmdbShow) {
    _ = io;

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    const fetch_url = try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/tv/{d}", .{tmdb_id});
    defer allocator.free(fetch_url);

    std.debug.print("TMDB TV Details Request URL: {s}\n", .{fetch_url});

    var response = try client.get(fetch_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB TV Details Response Status: {d}\n", .{response.status.code});

    if (response.status.code == 404) {
        return error.NotFound;
    }

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    const response_body = response.body orelse return error.EmptyResponseBody;

    return try std.json.parseFromSlice(types.TmdbShow, allocator, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

pub const ParsedShowCredits = struct {
    arena: std.heap.ArenaAllocator,
    value: types.TmdbCreditsResponse,

    pub fn deinit(self: ParsedShowCredits) void {
        var mut_arena = self.arena;
        mut_arena.deinit();
    }
};

pub fn fetchShowCredits(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmdb_id: i64,
    token: []const u8,
    proxy_url: ?[]const u8,
) !ParsedShowCredits {
    _ = io;

    var client = try client_mod.createClient(allocator, proxy_url);
    defer client.deinit();

    // Query show details with aggregate_credits and credits appended
    const fetch_url = try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/tv/{d}?append_to_response=aggregate_credits,credits", .{tmdb_id});
    defer allocator.free(fetch_url);

    std.debug.print("TMDB TV Credits Request URL: {s}\n", .{fetch_url});

    var response = try client.get(fetch_url, .{
        .bearer_token = token,
        .headers = &[_][2][]const u8{
            .{ "Accept", "application/json" },
        },
    });
    defer response.deinit();

    std.debug.print("TMDB TV Credits Response Status: {d}\n", .{response.status.code});

    if (response.status.code == 404) {
        return error.NotFound;
    }

    if (!response.status.isSuccess()) {
        return error.TmdbRequestFailed;
    }

    const response_body = response.body orelse return error.EmptyResponseBody;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try std.json.parseFromSlice(types.TmdbShowFullCreditsResponse, arena_alloc, response_body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });

    var cast_list = std.ArrayList(types.TmdbCastMember).empty;
    defer cast_list.deinit(arena_alloc);

    var crew_list = std.ArrayList(types.TmdbCrewMember).empty;
    defer crew_list.deinit(arena_alloc);

    // 1. Process creators from created_by
    for (parsed.value.created_by) |cb| {
        try crew_list.append(arena_alloc, .{
            .id = cb.id,
            .name = cb.name,
            .job = "Creator",
            .department = "Writing",
            .profile_path = cb.profile_path,
        });
    }

    // 2. Process cast from aggregate_credits
    if (parsed.value.aggregate_credits) |agg| {
        if (agg.cast.len > 0) {
            for (agg.cast) |c| {
                const char = if (c.roles.len > 0) c.roles[0].character else null;
                try cast_list.append(arena_alloc, .{
                    .id = c.id,
                    .name = c.name,
                    .character = char,
                    .profile_path = c.profile_path,
                    .order = c.order,
                });
            }
        }
    }

    // Fallback cast if aggregate_credits cast was empty
    if (cast_list.items.len == 0) {
        if (parsed.value.credits) |cr| {
            for (cr.cast) |c| {
                try cast_list.append(arena_alloc, c);
            }
        }
    }

    // 3. Process crew (directors, creators, etc.) from aggregate_credits
    if (parsed.value.aggregate_credits) |agg| {
        for (agg.crew) |cr| {
            for (cr.jobs) |j| {
                try crew_list.append(arena_alloc, .{
                    .id = cr.id,
                    .name = cr.name,
                    .job = j.job,
                    .department = cr.department,
                    .profile_path = cr.profile_path,
                });
            }
        }
    }

    // Fallback crew if aggregate_credits crew was empty
    if (crew_list.items.len == parsed.value.created_by.len) {
        if (parsed.value.credits) |cr| {
            for (cr.crew) |c| {
                try crew_list.append(arena_alloc, c);
            }
        }
    }

    return ParsedShowCredits{
        .arena = arena,
        .value = .{
            .id = parsed.value.id,
            .cast = try cast_list.toOwnedSlice(arena_alloc),
            .crew = try crew_list.toOwnedSlice(arena_alloc),
        },
    };
}


