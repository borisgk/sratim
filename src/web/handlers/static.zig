const std = @import("std");
const main = @import("../../main.zig");
pub const global_css: []const u8 = @embedFile("../style.css");
pub const favicon_ico = @embedFile("../favicon.ico");
pub const font_inter = @embedFile("../fonts/inter.woff2");
pub const font_outfit = @embedFile("../fonts/outfit.woff2");
pub const font_heebo_hebrew = @embedFile("../fonts/heebo-hebrew.woff2");
pub const bg_movies = @embedFile("../assets/movies.png");
pub const bg_shows = @embedFile("../assets/shows.png");
pub const bg_other = @embedFile("../assets/other.png");
pub const bg_main = @embedFile("../assets/main_bg.png");

/// Checks if the request target matches a known static asset route.
/// If matched, serves the static asset and returns `true`. Otherwise returns `false`.
pub fn serveStaticAsset(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io) !bool {
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

    // Route: Static Assets
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

    if (std.mem.startsWith(u8, target, "/assets/main_bg.png")) {
        try request.respond(bg_main, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/png" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    // Route: TMDB Images
    if (std.mem.startsWith(u8, target, "/images/")) {
        const query_idx = std.mem.indexOf(u8, target, "?");
        const clean_target = if (query_idx) |idx| target[0..idx] else target;
        const rel_path = clean_target["/images/".len..];

        const file_path = try std.fmt.allocPrint(allocator, "images/{s}", .{rel_path});
        defer allocator.free(file_path);

        const file_contents = main.app_dir.readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
            try request.respond("Not Found", .{ .status = .not_found });
            return true;
        };
        defer allocator.free(file_contents);

        try request.respond(file_contents, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "image/jpeg" },
                .{ .name = "Cache-Control", .value = "public, max-age=31536000, immutable" },
            },
        });
        return true;
    }

    return false;
}
