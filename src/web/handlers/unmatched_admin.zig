const std = @import("std");
const db_mod = @import("../../db/db.zig");
const unmatched_db = @import("../../db/unmatched.zig");
const template_engine = @import("../../core/template.zig");
const global_css: []const u8 = @embedFile("../style.css");

/// Escapes HTML special characters for safe rendering.
fn escapeHtml(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '&' => try list.appendSlice(allocator, "&amp;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\''=> try list.appendSlice(allocator, "&#39;"),
            else => try list.append(allocator, ch),
        }
    }
}

/// Serves the Unmatched Metadata page at GET /admin/unmatched
pub fn serveUnmatchedPage(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
) !void {
    const items = try unmatched_db.getUnmatchedItems(database, allocator);
    defer {
        for (items) |item| {
            allocator.free(item.item_type);
            allocator.free(item.title);
            allocator.free(item.file_path_or_path);
            allocator.free(item.library_name);
            allocator.free(item.library_type);
        }
        allocator.free(items);
    }

    var rows_buf = std.ArrayList(u8).empty;
    defer rows_buf.deinit(allocator);

    if (items.len == 0) {
        try rows_buf.appendSlice(allocator,
            \\<tr>
            \\  <td colspan="4" style="text-align: center; padding: 30px; color: #9ca3af;">
            \\    🎉 All media items are matched with TMDB metadata! No unmatched items found.
            \\  </td>
            \\</tr>
        );
    } else {
        for (items) |item| {
            try rows_buf.appendSlice(allocator, "<tr>\n  <td>\n    <div style=\"display: flex; flex-direction: column;\">\n      <span style=\"font-weight: 600; color: #f3f4f6;\">");
            try escapeHtml(&rows_buf, allocator, item.title);
            try rows_buf.appendSlice(allocator, "</span>\n      <span style=\"font-size: 0.8rem; color: #9ca3af; font-family: monospace; word-break: break-all;\">");
            try escapeHtml(&rows_buf, allocator, item.file_path_or_path);
            try rows_buf.appendSlice(allocator, "</span>\n    </div>\n  </td>\n");

            // Library column
            try rows_buf.appendSlice(allocator, "  <td>\n    <div style=\"display: flex; align-items: center; gap: 6px;\">\n      <span class=\"role-badge user\">");
            try escapeHtml(&rows_buf, allocator, item.library_name);
            try rows_buf.appendSlice(allocator, "</span>\n    </div>\n  </td>\n");

            // Status column
            try rows_buf.appendSlice(allocator, "  <td><span class=\"role-badge status-unmatched\">Unmatched</span></td>\n");

            // Actions column
            try rows_buf.appendSlice(allocator, "  <td style=\"text-align: right;\">\n    <div class=\"user-actions\">\n");

            // Auto Link button
            const auto_btn = try std.fmt.allocPrint(allocator,
                \\      <button type="button" class="action-btn toggle-btn" onclick="triggerAutoLink({d}, '{s}', this)">Auto Link</button>
                \\
            , .{ item.id, item.item_type });
            defer allocator.free(auto_btn);
            try rows_buf.appendSlice(allocator, auto_btn);

            // Live Search button
            const search_btn = try std.fmt.allocPrint(allocator,
                \\      <button type="button" class="action-btn reset-btn" onclick="openSearchModal({d}, '{s}', '{s}')">Search TMDB</button>
                \\
            , .{ item.id, item.item_type, item.title });
            defer allocator.free(search_btn);
            try rows_buf.appendSlice(allocator, search_btn);

            // Manual ID button
            const manual_btn = try std.fmt.allocPrint(allocator,
                \\      <button type="button" class="action-btn" onclick="openManualModal({d}, '{s}', '{s}')">TMDB ID</button>
                \\
            , .{ item.id, item.item_type, item.title });
            defer allocator.free(manual_btn);
            try rows_buf.appendSlice(allocator, manual_btn);

            try rows_buf.appendSlice(allocator, "    </div>\n  </td>\n</tr>\n");
        }
    }

    var count_buf: [32]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{items.len});

    const html_content = try template_engine.render(allocator, @embedFile("../templates/unmatched.html"), .{
        .INLINE_CSS = global_css,
        .UNMATCHED_ROWS = rows_buf.items,
        .TOTAL_UNMATCHED_COUNT = count_str,
    });

    request.respond(html_content, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    }) catch return;
}
