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
    extra_search_terms: ?[]const u8,
) !void {
    var tmdb_id_buf: [32]u8 = undefined;
    const tmdb_id_str = if (tmdb_id) |tid| (std.fmt.bufPrint(&tmdb_id_buf, "{d}", .{tid}) catch "") else "";
    var movie_id_buf: [32]u8 = undefined;
    const movie_id_str = std.fmt.bufPrint(&movie_id_buf, "{d}", .{movie_id}) catch "";
    const display_title = if (title_opt) |t| t else clean_name;

    try cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n            <div class=\"movie-card");
    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, " has-poster");
    }
    try cards_buf.appendSlice(allocator, "\" data-id=\"");
    try cards_buf.appendSlice(allocator, movie_id_str);
    try cards_buf.appendSlice(allocator, "\" data-tmdb-id=\"");
    try cards_buf.appendSlice(allocator, tmdb_id_str);
    try cards_buf.appendSlice(allocator, "\" data-name=\"");
    try utils.escapeHtml(cards_buf, allocator, display_title);
    if (file_path) |fp| {
        try cards_buf.appendSlice(allocator, " ");
        try utils.escapeHtml(cards_buf, allocator, fp);
    }
    if (extra_search_terms) |terms| {
        try cards_buf.appendSlice(allocator, " ");
        try utils.escapeHtml(cards_buf, allocator, terms);
    }
    try cards_buf.appendSlice(allocator, "\">\n");

    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, "                <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
        try cards_buf.appendSlice(allocator, poster_path_opt.?);
        try cards_buf.appendSlice(allocator, "\">\n");
    }

    if (is_admin) {
        try cards_buf.appendSlice(allocator,
            \\            <button class="context-menu-btn" title="Actions">
            \\                <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20">
            \\                    <circle cx="12" cy="5" r="2"/>
            \\                    <circle cx="12" cy="12" r="2"/>
            \\                    <circle cx="12" cy="19" r="2"/>
            \\                </svg>
            \\            </button>
            \\            <div class="context-dropdown">
            \\                <button class="dropdown-item lookup-btn" data-id="
        );
        try cards_buf.appendSlice(allocator, movie_id_str);
        try cards_buf.appendSlice(allocator,
            \\" data-type="movie">Lookup Metadata</button>
            \\                <button class="dropdown-item manual-id-btn" data-id="
        );
        try cards_buf.appendSlice(allocator, movie_id_str);
        try cards_buf.appendSlice(allocator, "\" data-type=\"movie\" data-tmdb-id=\"");
        try cards_buf.appendSlice(allocator, tmdb_id_str);
        try cards_buf.appendSlice(allocator,
            \\">Manual TMDB ID</button>
            \\                <button class="dropdown-item refetch-credits-btn" data-id="
        );
        try cards_buf.appendSlice(allocator, movie_id_str);
        try cards_buf.appendSlice(allocator,
            \\" data-type="movie">Refetch Cast</button>
            \\            </div>
            \\
        );
    }

    try cards_buf.appendSlice(allocator, "            <a href=\"/details?id=");
    try cards_buf.appendSlice(allocator, movie_id_str);
    try cards_buf.appendSlice(allocator,
        \\" class="play-link"></a>
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
    );

    if (progress_pct) |pct| {
        if (pct >= 1.0 and pct < 95.0) {
            var pct_buf: [32]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:.1}", .{pct}) catch "";
            try cards_buf.appendSlice(allocator,
                \\            <div class="card-progress">
                \\                <div class="progress-fill" style="width: 
            );
            try cards_buf.appendSlice(allocator, pct_str);
            try cards_buf.appendSlice(allocator,
                \\%;"></div>
                \\            </div>
                \\
            );
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
    var show_id_buf: [32]u8 = undefined;
    const show_id_str = std.fmt.bufPrint(&show_id_buf, "{d}", .{show_id}) catch "";

    try cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n            <div class=\"movie-card");
    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, " has-poster");
    }
    try cards_buf.appendSlice(allocator, "\" data-id=\"");
    try cards_buf.appendSlice(allocator, show_id_str);
    try cards_buf.appendSlice(allocator, "\" data-tmdb-id=\"");
    try cards_buf.appendSlice(allocator, tmdb_id_str);
    try cards_buf.appendSlice(allocator, "\" data-name=\"");
    try utils.escapeHtml(cards_buf, allocator, title);
    try cards_buf.appendSlice(allocator, "\">\n");

    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, "                <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
        try cards_buf.appendSlice(allocator, poster_path_opt.?);
        try cards_buf.appendSlice(allocator, "\">\n");
    }

    if (is_admin) {
        try cards_buf.appendSlice(allocator,
            \\            <button class="context-menu-btn" title="Actions">
            \\                <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20">
            \\                    <circle cx="12" cy="5" r="2"/>
            \\                    <circle cx="12" cy="12" r="2"/>
            \\                    <circle cx="12" cy="19" r="2"/>
            \\                </svg>
            \\            </button>
            \\            <div class="context-dropdown">
            \\                <button class="dropdown-item lookup-btn" data-id="
        );
        try cards_buf.appendSlice(allocator, show_id_str);
        try cards_buf.appendSlice(allocator,
            \\" data-type="show">Lookup Metadata</button>
            \\                <button class="dropdown-item manual-id-btn" data-id="
        );
        try cards_buf.appendSlice(allocator, show_id_str);
        try cards_buf.appendSlice(allocator, "\" data-type=\"show\" data-tmdb-id=\"");
        try cards_buf.appendSlice(allocator, tmdb_id_str);
        try cards_buf.appendSlice(allocator,
            \\">Manual TMDB ID</button>
            \\                <button class="dropdown-item refetch-credits-btn" data-id="
        );
        try cards_buf.appendSlice(allocator, show_id_str);
        try cards_buf.appendSlice(allocator,
            \\" data-type="show">Refetch Cast</button>
            \\            </div>
            \\
        );
    }

    try cards_buf.appendSlice(allocator, "            <a href=\"/show?id=");
    try cards_buf.appendSlice(allocator, show_id_str);
    try cards_buf.appendSlice(allocator,
        \\" class="play-link"></a>
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
    );

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
    var episode_id_buf: [32]u8 = undefined;
    const episode_id_str = std.fmt.bufPrint(&episode_id_buf, "{d}", .{episode_id}) catch "";

    try cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n            <div class=\"movie-card");
    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, " has-poster");
    }
    try cards_buf.appendSlice(allocator, "\" data-id=\"");
    try cards_buf.appendSlice(allocator, episode_id_str);
    try cards_buf.appendSlice(allocator, "\" data-name=\"");
    try utils.escapeHtml(cards_buf, allocator, show_title);
    try cards_buf.appendSlice(allocator, " ");
    try utils.escapeHtml(cards_buf, allocator, ep_display_name);
    try cards_buf.appendSlice(allocator, "\">\n");

    if (poster_path_opt != null and poster_path_opt.?.len > 0) {
        try cards_buf.appendSlice(allocator, "                <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
        try cards_buf.appendSlice(allocator, poster_path_opt.?);
        try cards_buf.appendSlice(allocator, "\">\n");
    }

    try cards_buf.appendSlice(allocator, "            <a href=\"/player?episode_id=");
    try cards_buf.appendSlice(allocator, episode_id_str);
    try cards_buf.appendSlice(allocator,
        \\" class="play-link"></a>
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
        \\                    <span class="type-badge">
    );
    try utils.escapeHtml(cards_buf, allocator, ep_badge);
    try cards_buf.appendSlice(allocator,
        \\</span>
        \\                </div>
        \\            </div>
        \\
    );

    if (progress_pct) |pct| {
        if (pct >= 1.0 and pct < 95.0) {
            var pct_buf: [32]u8 = undefined;
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d:.1}", .{pct}) catch "";
            try cards_buf.appendSlice(allocator,
                \\            <div class="card-progress">
                \\                <div class="progress-fill" style="width: 
            );
            try cards_buf.appendSlice(allocator, pct_str);
            try cards_buf.appendSlice(allocator,
                \\%;"></div>
                \\            </div>
                \\
            );
        }
    }

    try cards_buf.appendSlice(allocator, "        </div>\n        <h3 class=\"movie-title\">");
    try utils.escapeHtml(cards_buf, allocator, show_title);
    try cards_buf.appendSlice(allocator, " - ");
    try utils.escapeHtml(cards_buf, allocator, ep_display_name);
    try cards_buf.appendSlice(allocator, "</h3>\n    </div>\n");
}
