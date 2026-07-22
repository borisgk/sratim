const std = @import("std");
const db_mod = @import("../../db/db.zig");
const admin_db = @import("../../db/admin.zig");
const template_engine = @import("../../core/template.zig");
const minify = @import("../../core/minify.zig");
const global_css: []const u8 = minify.minifyCss(@embedFile("../style.css"));

/// Serves the Admin Dashboard page displaying catalog, storage, user, and unmatched metrics.
pub fn serveAdminPage(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database) !void {
    const stats = try admin_db.getAdminStats(database);

    var movies_buf: [32]u8 = undefined;
    const movies_str = try std.fmt.bufPrint(&movies_buf, "{d}", .{stats.total_movies});

    var shows_buf: [32]u8 = undefined;
    const shows_str = try std.fmt.bufPrint(&shows_buf, "{d}", .{stats.total_shows});

    var episodes_buf: [32]u8 = undefined;
    const episodes_str = try std.fmt.bufPrint(&episodes_buf, "{d}", .{stats.total_episodes});

    var other_buf: [32]u8 = undefined;
    const other_str = try std.fmt.bufPrint(&other_buf, "{d}", .{stats.total_other_files});

    var users_buf: [32]u8 = undefined;
    const users_str = try std.fmt.bufPrint(&users_buf, "{d}", .{stats.total_users});

    var unmatched_buf: [32]u8 = undefined;
    const unmatched_str = try std.fmt.bufPrint(&unmatched_buf, "{d}", .{stats.total_unmatched});

    const storage_str = try admin_db.formatBytes(allocator, stats.total_storage_bytes);
    defer allocator.free(storage_str);

    const html_content = try template_engine.render(allocator, @embedFile("../templates/admin.html"), .{
        .INLINE_CSS = global_css,
        .TOTAL_MOVIES = movies_str,
        .TOTAL_SHOWS = shows_str,
        .TOTAL_EPISODES = episodes_str,
        .TOTAL_OTHER_FILES = other_str,
        .TOTAL_USERS = users_str,
        .TOTAL_UNMATCHED = unmatched_str,
        .TOTAL_STORAGE = storage_str,
    });

    request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    }) catch return;
}
