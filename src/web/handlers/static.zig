const std = @import("std");
const minify = @import("../../core/minify.zig");

pub const global_css: []const u8 = minify.minifyCss(@embedFile("../style.css"));
pub const favicon_ico = @embedFile("../favicon.ico");
pub const font_inter = @embedFile("../fonts/inter.woff2");
pub const font_outfit = @embedFile("../fonts/outfit.woff2");

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

    // Route: TMDB Images
    if (std.mem.startsWith(u8, target, "/images/")) {
        const query_idx = std.mem.indexOf(u8, target, "?");
        const clean_target = if (query_idx) |idx| target[0..idx] else target;
        const rel_path = clean_target["/images/".len..];

        const file_path = try std.fmt.allocPrint(allocator, "images/{s}", .{rel_path});
        defer allocator.free(file_path);

        const file_contents = std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
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
