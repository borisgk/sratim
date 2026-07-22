const std = @import("std");
const db_mod = @import("../../db/db.zig");
const logging_mod = @import("../../db/logging.zig");
const template_engine = @import("../../core/template.zig");
const minify = @import("../../core/minify.zig");
const global_css: []const u8 = minify.minifyCss(@embedFile("../style.css"));

fn escapeHtml(writer: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '&' => try writer.appendSlice(allocator, "&amp;"),
            '<' => try writer.appendSlice(allocator, "&lt;"),
            '>' => try writer.appendSlice(allocator, "&gt;"),
            '"' => try writer.appendSlice(allocator, "&quot;"),
            '\'' => try writer.appendSlice(allocator, "&#39;"),
            else => try writer.append(allocator, c),
        }
    }
}

pub fn handleShow(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    username: []const u8,
    show_id: i64,
) !void {
    _ = logs_database;
    _ = username;

    var stmt = try database.prepare("SELECT title, overview, poster_path, backdrop_path, library_id FROM shows WHERE id = ?1;");
    defer stmt.finalize();
    try stmt.bindInt64(1, show_id);

    if ((try stmt.step()) != .row) {
        try request.respond("Show not found", .{ .status = .not_found });
        return;
    }

    const title = stmt.columnText(0).?;
    const overview = stmt.columnText(1);
    const poster_path = stmt.columnText(2);
    const backdrop_path = stmt.columnText(3);
    const library_id = stmt.columnInt64(4);
    
    _ = overview;
    _ = poster_path;

    var ep_stmt = try database.prepare(
        \\SELECT id, file_path, season, episode, is_present, title, overview, still_path
        \\FROM episodes 
        \\WHERE show_id = ?1 AND is_present = 1
        \\ORDER BY season ASC, episode ASC;
    );
    defer ep_stmt.finalize();
    try ep_stmt.bindInt64(1, show_id);

    var seasons_buf = std.ArrayList(u8).empty;
    defer seasons_buf.deinit(allocator);

    var current_season: i32 = -1;

    while ((try ep_stmt.step()) == .row) {
        const ep_id = ep_stmt.columnInt64(0);
        const file_path = ep_stmt.columnText(1).?;
        const season = ep_stmt.columnInt(2);
        const episode = ep_stmt.columnInt(3);

        if (season != current_season) {
            if (current_season != -1) {
                try seasons_buf.appendSlice(allocator, "</div>\n");
            }
            current_season = season;
            const season_header = try std.fmt.allocPrint(allocator, "<h2 style=\"margin-bottom: 20px; margin-top: 40px;\">Season {d}</h2>\n<div class=\"episode-list\" id=\"movie-grid\">\n", .{season});
            defer allocator.free(season_header);
            try seasons_buf.appendSlice(allocator, season_header);
        }

        const ep_title_opt = ep_stmt.columnText(5);
        const ep_overview_opt = ep_stmt.columnText(6);
        const ep_still_path_opt = ep_stmt.columnText(7);
        const basename = std.fs.path.basename(file_path);
        
        var buf: [16]u8 = undefined;
        const ep_num = try std.fmt.bufPrint(&buf, "Episode {d}", .{episode});

        const display_title = if (ep_title_opt) |t| t else basename;
        const display_overview = if (ep_overview_opt) |o| o else "No description available.";

        try seasons_buf.appendSlice(allocator, "    <div class=\"episode-row\" data-name=\"");
        try escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "\">\n");
        
        if (ep_still_path_opt != null and ep_still_path_opt.?.len > 0) {
            try seasons_buf.appendSlice(allocator, "        <div class=\"episode-card has-poster\">\n");
        } else {
            try seasons_buf.appendSlice(allocator, "        <div class=\"episode-card\">\n");
        }
        
        if (ep_still_path_opt != null and ep_still_path_opt.?.len > 0) {
            try seasons_buf.appendSlice(allocator, "            <img class=\"poster-img\" loading=\"lazy\" alt=\"still\" src=\"/images/backdrops/original");
            try seasons_buf.appendSlice(allocator, ep_still_path_opt.?);
            try seasons_buf.appendSlice(allocator, "\">\n");
        }

        const dropdown_content = try std.fmt.allocPrint(allocator,
            \\            <a href="/player?episode_id={d}" class="play-link"></a>
            \\            <div class="card-content">
            \\                <div class="card-top">
            \\                    <div class="icon-wrapper">
            \\                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24">
            \\                            <path d="M15 10l5-3.07v10.14L15 14v-4z" stroke-linecap="round" stroke-linejoin="round"/>
            \\                            <rect x="4" y="6" width="11" height="12" rx="2" stroke-linecap="round" stroke-linejoin="round"/>
            \\                        </svg>
            \\                    </div>
            \\                </div>
            \\            </div>
            \\        </div>
            \\        <div class="episode-info">
            \\            <h3 class="episode-title" title="
        , .{ ep_id });
        defer allocator.free(dropdown_content);
        try seasons_buf.appendSlice(allocator, dropdown_content);

        try escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "\">");
        try seasons_buf.appendSlice(allocator, ep_num);
        try seasons_buf.appendSlice(allocator, " - ");
        try escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "</h3>\n");
        
        try seasons_buf.appendSlice(allocator, "            <p class=\"episode-overview\">");
        try escapeHtml(&seasons_buf, allocator, display_overview);
        try seasons_buf.appendSlice(allocator, "</p>\n        </div>\n    </div>\n");
    }
    
    if (current_season != -1) {
        try seasons_buf.appendSlice(allocator, "</div>\n");
    } else {
        try seasons_buf.appendSlice(allocator, "<p>No episodes found.</p>\n");
    }

    var lib_id_buf: [32]u8 = undefined;
    const lib_id_str = try std.fmt.bufPrint(&lib_id_buf, "{d}", .{library_id});

    var lib_stmt = try database.prepare("SELECT name FROM libraries WHERE id = ?1;");
    defer lib_stmt.finalize();
    try lib_stmt.bindInt64(1, library_id);
    const lib_name = if ((try lib_stmt.step()) == .row) lib_stmt.columnText(0).? else "Library";

    var backdrop_html = std.ArrayList(u8).empty;
    defer backdrop_html.deinit(allocator);

    if (backdrop_path != null and backdrop_path.?.len > 0) {
        try backdrop_html.appendSlice(allocator, "<div class=\"show-backdrop\" style=\"background-image: url('/images/backdrops/original");
        try backdrop_html.appendSlice(allocator, backdrop_path.?);
        try backdrop_html.appendSlice(allocator, "')\"></div>");
    }

    const html = try template_engine.render(allocator, @embedFile("../templates/show_view.html"), .{
        .INLINE_CSS = global_css,
        .SHOW_TITLE = title,
        .LIBRARY_ID = lib_id_str,
        .LIBRARY_NAME = lib_name,
        .SEASONS_HTML = seasons_buf.items,
        .SHOW_BACKDROP_HTML = backdrop_html.items,
    });
    defer allocator.free(html);

    try request.respond(html, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}
