const std = @import("std");
const db_mod = @import("../../db/db.zig");
const admin_db = @import("../../db/admin.zig");
const library_mod = @import("../../db/library.zig");
const utils = @import("../utils.zig");
const template_engine = @import("../../core/template.zig");
const global_css: []const u8 = @embedFile("../style.css");

/// Serves the Admin Dashboard page displaying catalog, storage, user, and unmatched metrics.
pub fn serveAdminPage(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database) !void {
    const stats = try admin_db.getAdminStats(database, allocator);

    var movies_buf: [32]u8 = undefined;
    const movies_str = try std.fmt.bufPrint(&movies_buf, "{d}", .{stats.total_movies});

    var shows_buf: [32]u8 = undefined;
    const shows_str = try std.fmt.bufPrint(&shows_buf, "{d}", .{stats.total_shows});

    var episodes_buf: [32]u8 = undefined;
    const episodes_str = try std.fmt.bufPrint(&episodes_buf, "{d}", .{stats.total_episodes});

    var other_buf: [32]u8 = undefined;
    const other_str = try std.fmt.bufPrint(&other_buf, "{d}", .{stats.total_other_files});

    var directors_buf: [32]u8 = undefined;
    const directors_str = try std.fmt.bufPrint(&directors_buf, "{d}", .{stats.total_directors});

    var actors_buf: [32]u8 = undefined;
    const actors_str = try std.fmt.bufPrint(&actors_buf, "{d}", .{stats.total_actors});

    var users_buf: [32]u8 = undefined;
    const users_str = try std.fmt.bufPrint(&users_buf, "{d}", .{stats.total_users});

    var unmatched_buf: [32]u8 = undefined;
    const unmatched_str = try std.fmt.bufPrint(&unmatched_buf, "{d}", .{stats.total_unmatched});

    const storage_str = try admin_db.formatBytes(allocator, stats.total_storage_bytes);
    defer allocator.free(storage_str);

    const libraries = try library_mod.getLibraries(database, allocator);
    defer {
        for (libraries) |lib| {
            allocator.free(lib.name);
            allocator.free(lib.path);
            allocator.free(lib.metadata_language);
            if (lib.ignore_patterns) |pat| allocator.free(pat);
        }
        allocator.free(libraries);
    }

    var rows_buf = std.ArrayList(u8).empty;
    defer rows_buf.deinit(allocator);

    if (libraries.len == 0) {
        try rows_buf.appendSlice(allocator, "<tr><td colspan=\"4\" style=\"text-align: center; color: #9ca3af; padding: 24px;\">No libraries configured.</td></tr>");
    } else {
        for (libraries) |lib| {
            var escaped_name = std.ArrayList(u8).empty;
            defer escaped_name.deinit(allocator);
            try utils.escapeHtml(&escaped_name, allocator, lib.name);

            var escaped_path = std.ArrayList(u8).empty;
            defer escaped_path.deinit(allocator);
            try utils.escapeHtml(&escaped_path, allocator, lib.path);

            const row = try std.fmt.allocPrint(allocator,
                \\<tr>
                \\    <td>
                \\        <span class="user-name" id="lib-name-{d}">{s}</span>
                \\    </td>
                \\    <td>
                \\        <span class="role-badge user">{s}</span>
                \\    </td>
                \\    <td style="color: #9ca3af; font-family: monospace; font-size: 0.85rem; max-width: 320px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;">
                \\        {s}
                \\    </td>
                \\    <td style="text-align: right; white-space: nowrap;">
                \\        <button type="button" class="admin-rename-btn" data-id="{d}" style="padding: 6px 14px; background: rgba(168, 85, 247, 0.15); border: 1px solid rgba(168, 85, 247, 0.3); border-radius: 10px; color: #c084fc; cursor: pointer; font-size: 0.85rem; margin-right: 8px;">
                \\            Rename
                \\        </button>
                \\        <a href="/library?id={d}" style="display: inline-block; padding: 6px 14px; background: rgba(255, 255, 255, 0.05); border: 1px solid rgba(255, 255, 255, 0.1); border-radius: 10px; color: #d1d5db; text-decoration: none; font-size: 0.85rem; margin-right: 8px;">
                \\            Browse
                \\        </a>
                \\        <button type="button" class="admin-delete-btn" data-id="{d}" style="padding: 6px 14px; background: rgba(239, 68, 68, 0.15); border: 1px solid rgba(239, 68, 68, 0.3); border-radius: 10px; color: #f87171; cursor: pointer; font-size: 0.85rem;">
                \\            Delete
                \\        </button>
                \\    </td>
                \\</tr>
            , .{ lib.id, escaped_name.items, lib.lib_type.toString(), escaped_path.items, lib.id, lib.id, lib.id });
            defer allocator.free(row);
            try rows_buf.appendSlice(allocator, row);
        }
    }

    const html_content = try template_engine.render(allocator, @embedFile("../templates/admin.html"), .{
        .INLINE_CSS = global_css,
        .TOTAL_MOVIES = movies_str,
        .TOTAL_SHOWS = shows_str,
        .TOTAL_EPISODES = episodes_str,
        .TOTAL_OTHER_FILES = other_str,
        .TOTAL_DIRECTORS = directors_str,
        .TOTAL_ACTORS = actors_str,
        .TOTAL_USERS = users_str,
        .TOTAL_UNMATCHED = unmatched_str,
        .TOTAL_STORAGE = storage_str,
        .LIBRARY_ROWS = rows_buf.items,
    });

    request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    }) catch return;
}
