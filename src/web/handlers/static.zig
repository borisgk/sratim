const std = @import("std");
const main = @import("../../main.zig");
const config_mod = @import("../../config.zig");
const tmdb_client = @import("../../media/tmdb/client.zig");
pub const global_css: []const u8 = @embedFile("../style.css");
pub const favicon_ico = @embedFile("../favicon.ico");
pub const font_inter = @embedFile("../fonts/inter.woff2");
pub const font_outfit = @embedFile("../fonts/outfit.woff2");
pub const font_heebo_hebrew = @embedFile("../fonts/heebo-hebrew.woff2");
pub const bg_movies = @embedFile("../assets/movies.png");
pub const bg_shows = @embedFile("../assets/shows.png");
pub const bg_other = @embedFile("../assets/other.png");

/// Checks if the request target matches a known static asset route.
/// If matched, serves the static asset and returns `true`. Otherwise returns `false`.
pub fn serveStaticAsset(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io, config: *const config_mod.Config) !bool {
    const target = request.head.target;

    // Route: Stylesheet
    if (std.mem.startsWith(u8, target, "/style.css")) {
        try request.respond(global_css, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/css; charset=utf-8" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    // Route: Favicon
    if (std.mem.startsWith(u8, target, "/favicon.ico")) {
        try request.respond(favicon_ico, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/x-icon" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    // Route: Fonts
    if (std.mem.startsWith(u8, target, "/fonts/inter.woff2")) {
        try request.respond(font_inter, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    if (std.mem.startsWith(u8, target, "/fonts/outfit.woff2")) {
        try request.respond(font_outfit, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    if (std.mem.startsWith(u8, target, "/fonts/heebo-hebrew.woff2")) {
        try request.respond(font_heebo_hebrew, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "font/woff2" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    // Route: Asset images
    if (std.mem.startsWith(u8, target, "/assets/movies.png")) {
        try request.respond(bg_movies, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/png" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    if (std.mem.startsWith(u8, target, "/assets/shows.png")) {
        try request.respond(bg_shows, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/png" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    if (std.mem.startsWith(u8, target, "/assets/other.png")) {
        try request.respond(bg_other, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/png" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    // Route: TMDB Images (with on-demand caching)
    if (std.mem.startsWith(u8, target, "/images/")) {
        const query_idx = std.mem.indexOf(u8, target, "?");
        const clean_target = if (query_idx) |idx| target[0..idx] else target;
        const rel_path = clean_target["/images/".len..];

        const file_path = try std.fmt.allocPrint(allocator, "images/{s}", .{rel_path});
        defer allocator.free(file_path);

        // 1. Serve from local cache if present
        if (main.app_dir.readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024))) |file_contents| {
            defer allocator.free(file_contents);
            try request.respond(file_contents, .{
                .status = .ok,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "image/jpeg" },
                    .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                },
            });
            return true;
        } else |_| {}

        // 2. On-demand proxy fetch from TMDB and cache to disk
        // rel_path format is "{category}/{size}/{filename}", e.g. "profiles/w185/abc.jpg"
        if (std.mem.indexOfScalar(u8, rel_path, '/')) |slash_idx| {
            const tmdb_subpath = rel_path[slash_idx + 1 ..];
            const tmdb_url = try std.fmt.allocPrint(allocator, "https://image.tmdb.org/t/p/{s}", .{tmdb_subpath});
            defer allocator.free(tmdb_url);

            if (tmdb_client.createClient(allocator, config.tmdb_proxy)) |*client_val| {
                var client = client_val.*;
                defer client.deinit();

                if (client.get(tmdb_url, .{})) |response| {
                    var res = response;
                    defer res.deinit();

                    if (res.status.isSuccess() and res.body != null) {
                        const body = res.body.?;
                        if (std.mem.lastIndexOfScalar(u8, file_path, '/')) |last_slash| {
                            main.app_dir.createDirPath(io, file_path[0..last_slash]) catch {};
                        }
                        main.app_dir.writeFile(io, .{ .sub_path = file_path, .data = body }) catch {};

                        try request.respond(body, .{
                            .status = .ok,
                            .extra_headers = &.{
                                .{ .name = "content-type", .value = "image/jpeg" },
                                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
                            },
                        });
                        return true;
                    }
                } else |_| {}
            } else |_| {}
        }

        try request.respond("Not Found", .{ .status = .not_found });
        return true;
    }

    return false;
}
