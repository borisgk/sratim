const std = @import("std");
const utils = @import("../utils.zig");

/// Appends a movie card HTML element to the cards buffer.
pub fn appendMovieCard(
    cards_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    movie_id: i64,
    file_path: ?[]const u8,
    clean_name: []const u8,
    title_opt: ?[]const u8,
    poster_path_opt: ?[]const u8,
    tmdb_id: ?i64,
    progress_pct: ?f64,
    is_admin: bool,
) !void {
    var tmdb_id_buf: [32]u8 = undefined;
    const tmdb_id_str = if (tmdb_id) |tid| (std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "") else "";
    const display_title = if (title_opt) |t| t else clean_name;

    try cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n");
    const card_header = try std.fmt.allocPrint(allocator, "            <div class=\"movie-card{s}\" data-id=\"{d}\" data-tmdb-id=\"{s}\" data-name=\"", .{
        if (poster_path_opt != null and poster_path_opt.?.len > 0) " has-poster" else "",
        movie_id,
        tmdb_id_str,
    });
    defer allocator.free(card_header);
    try cards_buf.appendSlice(allocator, card_header);
    try utils.escapeHtml(cards_buf, allocator, display_title);
    if (file_path) |fp| {
        try cards_buf.appendSlice(allocator, " ");
        try utils.escapeHtml(cards_buf, allocator, fp);
    }
    try cards_buf.appendSlice(allocator, "\">\n");
    
    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, "                <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
        try cards_buf.appendSlice(allocator, poster_path_opt.?);
        try cards_buf.appendSlice(allocator, "\">\n");
    }
    if (is_admin) {
        try cards_buf.appendSlice(allocator, "            <button class=\"context-menu-btn\" title=\"Actions\">\n                <svg viewBox=\"0 0 24 24\" fill=\"currentColor\" width=\"20\" height=\"20\">\n                    <circle cx=\"12\" cy=\"5\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"12\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"19\" r=\"2\"/>\n                </svg>\n            </button>\n            <div class=\"context-dropdown\">\n");
        const dropdown_content = try std.fmt.allocPrint(allocator,
            \\                <button class="dropdown-item lookup-btn" data-id="{d}" data-type="movie">Lookup Metadata</button>
            \\                <button class="dropdown-item manual-id-btn" data-id="{d}" data-type="movie" data-tmdb-id="{s}">Manual TMDB ID</button>
            \\            </div>
            \\
        , .{ movie_id, movie_id, tmdb_id_str });
        defer allocator.free(dropdown_content);
        try cards_buf.appendSlice(allocator, dropdown_content);
    }

    const play_link = try std.fmt.allocPrint(allocator,
        \\            <a href="/details?id={d}" class="play-link"></a>
        \\
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
        \\
    , .{movie_id});
    defer allocator.free(play_link);
    try cards_buf.appendSlice(allocator, play_link);

    if (progress_pct) |pct| {
        if (pct >= 1.0 and pct < 95.0) {
            const progress_str = try std.fmt.allocPrint(allocator,
                \\            <div class="card-progress">
                \\                <div class="progress-fill" style="width: {d:.1}%;"></div>
                \\            </div>
                \\
            , .{pct});
            defer allocator.free(progress_str);
            try cards_buf.appendSlice(allocator, progress_str);
        }
    }

    try cards_buf.appendSlice(allocator, "        </div>\n        <h3 class=\"movie-title\">");
    try utils.escapeHtml(cards_buf, allocator, display_title);
    try cards_buf.appendSlice(allocator, "</h3>\n    </div>\n");
}

/// Appends a show card HTML element to the cards buffer.
pub fn appendShowCard(
    cards_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    show_id: i64,
    title: []const u8,
    poster_path_opt: ?[]const u8,
    tmdb_id: ?i64,
    is_admin: bool,
) !void {
    var tmdb_id_buf: [32]u8 = undefined;
    const tmdb_id_str = if (tmdb_id) |tid| (std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "") else "";

    try cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n");
    const card_header = try std.fmt.allocPrint(allocator, "            <div class=\"movie-card{s}\" data-id=\"{d}\" data-tmdb-id=\"{s}\" data-name=\"", .{
        if (poster_path_opt != null and poster_path_opt.?.len > 0) " has-poster" else "",
        show_id,
        tmdb_id_str,
    });
    defer allocator.free(card_header);
    try cards_buf.appendSlice(allocator, card_header);
    try utils.escapeHtml(cards_buf, allocator, title);
    try cards_buf.appendSlice(allocator, "\">\n");

    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, "                <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
        try cards_buf.appendSlice(allocator, poster_path_opt.?);
        try cards_buf.appendSlice(allocator, "\">\n");
    }

    if (is_admin) {
        try cards_buf.appendSlice(allocator, "            <button class=\"context-menu-btn\" title=\"Actions\">\n                <svg viewBox=\"0 0 24 24\" fill=\"currentColor\" width=\"20\" height=\"20\">\n                    <circle cx=\"12\" cy=\"5\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"12\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"19\" r=\"2\"/>\n                </svg>\n            </button>\n            <div class=\"context-dropdown\">\n");
        const dropdown_content = try std.fmt.allocPrint(allocator,
            \\                <button class="dropdown-item lookup-btn" data-id="{d}" data-type="show">Lookup Metadata</button>
            \\                <button class="dropdown-item manual-id-btn" data-id="{d}" data-type="show" data-tmdb-id="{s}">Manual TMDB ID</button>
            \\            </div>
            \\
        , .{ show_id, show_id, tmdb_id_str });
        defer allocator.free(dropdown_content);
        try cards_buf.appendSlice(allocator, dropdown_content);
    }

    const play_link = try std.fmt.allocPrint(allocator,
        \\            <a href="/show?id={d}" class="play-link"></a>
        \\
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
        \\
    , .{show_id});
    defer allocator.free(play_link);
    try cards_buf.appendSlice(allocator, play_link);

    try cards_buf.appendSlice(allocator, "        </div>\n        <h3 class=\"movie-title\">");
    try utils.escapeHtml(cards_buf, allocator, title);
    try cards_buf.appendSlice(allocator, "</h3>\n    </div>\n");
}

/// Appends a recently watched episode card HTML element to the cards buffer.
pub fn appendEpisodeRecentCard(
    cards_buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    episode_id: i64,
    show_title: []const u8,
    ep_display_name: []const u8,
    poster_path_opt: ?[]const u8,
    ep_badge: []const u8,
    progress_pct: ?f64,
) !void {
    try cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n");
    const card_header = try std.fmt.allocPrint(allocator, "            <div class=\"movie-card{s}\" data-id=\"{d}\" data-name=\"", .{
        if (poster_path_opt != null and poster_path_opt.?.len > 0) " has-poster" else "",
        episode_id,
    });
    defer allocator.free(card_header);
    try cards_buf.appendSlice(allocator, card_header);
    try utils.escapeHtml(cards_buf, allocator, show_title);
    try cards_buf.appendSlice(allocator, " ");
    try utils.escapeHtml(cards_buf, allocator, ep_display_name);
    try cards_buf.appendSlice(allocator, "\">\n");

    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, "                <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
        try cards_buf.appendSlice(allocator, poster_path_opt.?);
        try cards_buf.appendSlice(allocator, "\">\n");
    }

    const play_link = try std.fmt.allocPrint(allocator,
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
        \\                <div class="card-bottom">
        \\                    <span class="type-badge">{s}</span>
        \\                </div>
        \\            </div>
        \\
    , .{ episode_id, ep_badge });
    defer allocator.free(play_link);
    try cards_buf.appendSlice(allocator, play_link);

    if (progress_pct) |pct| {
        if (pct >= 1.0 and pct < 95.0) {
            const progress_str = try std.fmt.allocPrint(allocator,
                \\            <div class="card-progress">
                \\                <div class="progress-fill" style="width: {d:.1}%;"></div>
                \\            </div>
                \\
            , .{pct});
            defer allocator.free(progress_str);
            try cards_buf.appendSlice(allocator, progress_str);
        }
    }

    try cards_buf.appendSlice(allocator, "        </div>\n        <h3 class=\"movie-title\">");
    try utils.escapeHtml(cards_buf, allocator, show_title);
    try cards_buf.appendSlice(allocator, " - ");
    try utils.escapeHtml(cards_buf, allocator, ep_display_name);
    try cards_buf.appendSlice(allocator, "</h3>\n    </div>\n");
}
