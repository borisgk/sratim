const std = @import("std");
const httpx = @import("httpx");

pub const TmdbMovie = struct {
    id: i64,
    title: []const u8,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
};

pub const TmdbSearchResponse = struct {
    results: []TmdbMovie,
};

fn writePercentEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    const hex_chars = "0123456789ABCDEF";
    for (input) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try list.append(allocator, ch);
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, hex_chars[ch >> 4]);
            try list.append(allocator, hex_chars[ch & 15]);
        }
    }
}

pub fn searchMovie(
    allocator: std.mem.Allocator,
    io: std.Io,
    query: []const u8,
    year: ?[]const u8,
    token: []const u8,
    proxy_url: ?[]const u8,
) !std.json.Parsed(TmdbSearchResponse) {
    _ = io;

    // Configure proxy if provided
    var config = httpx.ClientConfig.defaults();
    if (proxy_url) |p_url| {
        if (p_url.len > 0) {
            const uri = try std.Uri.parse(p_url);
            const host_bytes = switch (uri.host.?) {
                .raw => |r| r,
                .percent_encoded => |p| p,
            };

            var kind: httpx.ProxyKind = .http;
            if (std.mem.eql(u8, uri.scheme, "socks5") or
                std.mem.eql(u8, uri.scheme, "socks5h") or
                std.mem.eql(u8, uri.scheme, "socks"))
            {
                kind = .socks5h;
            }

            const port = uri.port orelse switch (kind) {
                .socks5h => 1080,
                .http => if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else @as(u16, 80),
            };

            config = config.withProxy(.{
                .kind = kind,
                .host = host_bytes,
                .port = port,
                .username = null,
                .password = null,
            });
        }
    }

    var client = httpx.Client.initWithConfig(allocator, config);
    defer client.deinit();

    // Build Search URL
    var query_encoded = std.ArrayList(u8).empty;
    defer query_encoded.deinit(allocator);
    try writePercentEncoded(&query_encoded, allocator, query);

    const search_url = if (year) |y|
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}&primary_release_year={s}", .{query_encoded.items, y})
    else
        try std.fmt.allocPrint(allocator, "https://api.themoviedb.org/3/search/movie?query={s}", .{query_encoded.items});
    defer allocator.free(search_url);

    // Perform Fetch
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

    // Parse Response
    const parsed = try std.json.parseFromSlice(TmdbSearchResponse, allocator, response_body, .{
        .ignore_unknown_fields = true,
    });
    
    return parsed;
}

test "searchMovie test" {
    const allocator = std.testing.allocator;
    
    var file = std.fs.cwd().openFile("config.json", .{}) catch |err| {
        std.debug.print("Skipping test, config.json not found: {}\n", .{err});
        return;
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024*1024);
    defer allocator.free(content);
    
    const Config = struct {
        tmdb_access_token: ?[]const u8 = null,
        tmdb_proxy: ?[]const u8 = null,
    };
    const parsed = try std.json.parseFromSlice(Config, allocator, content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    
    const token = parsed.value.tmdb_access_token orelse return;
    if (token.len == 0) return;
    
    var t = std.Io.Threaded.init(allocator, .{});
    const io = t.io();
    
    const results = try searchMovie(allocator, io, "Inception", "2010", token, parsed.value.tmdb_proxy);
    defer results.deinit();
    
    try std.testing.expect(results.value.results.len > 0);
    std.debug.print("Search result first movie: {s}\n", .{results.value.results[0].title});
}

