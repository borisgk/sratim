const std = @import("std");
const template_engine = @import("../../core/template.zig");
const db_mod = @import("../../db/db.zig");
const library_mod = @import("../../db/library.zig");
const logging_mod = @import("../../db/logging.zig");
const cards = @import("cards.zig");
const utils = @import("../utils.zig");
const build_options = @import("build_options");

const global_css: []const u8 = @embedFile("../style.css");

/// Generates the HTML catalog of libraries along with recently watched shelf.
pub fn generateHtml(
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    username: []const u8,
    is_admin: bool,
) ![]u8 {
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

    var cards_buf = std.ArrayList(u8).empty;
    defer cards_buf.deinit(allocator);

    if (libraries.len == 0) {
        try cards_buf.appendSlice(allocator,
            \\            <div class="empty-state">
            \\                <h3>No Libraries Configured</h3>
            \\                <p>Get started by adding a media folder. Click the '+' button in the bottom right corner.</p>
            \\            </div>
        );
    } else {
        for (libraries) |lib| {
            const bg_image = switch (lib.lib_type) {
                .Movies => "/assets/movies.png",
                .Shows => "/assets/shows.png",
                .Other => "/assets/other.png",
            };

            const card_start = try std.fmt.allocPrint(allocator, "            <a href=\"/library?id={d}\" class=\"library-card\" style=\"background-image: linear-gradient(to top, rgba(0,0,0,0.95) 0%, rgba(0,0,0,0.4) 50%, rgba(0,0,0,0.1) 100%), url('{s}');\">\n", .{lib.id, bg_image});
            defer allocator.free(card_start);
            try cards_buf.appendSlice(allocator, card_start);

            try cards_buf.appendSlice(allocator, "                <div class=\"card-top\">\n                    <div class=\"card-info\">\n                        <h3 class=\"library-title\">");
            try utils.escapeHtml(&cards_buf, allocator, lib.name);
            try cards_buf.appendSlice(allocator, "</h3>\n                    </div>\n                </div>\n                <div class=\"card-bottom\">\n                    <span class=\"type-badge\">");
            try cards_buf.appendSlice(allocator, lib.lib_type.toString());
            try cards_buf.appendSlice(allocator, "</span>\n                </div>\n            </a>\n");
        }
    }

    // Generate Recently Watched section for movies and episodes
    var recently_watched_section_buf = std.ArrayList(u8).empty;
    defer recently_watched_section_buf.deinit(allocator);

    const recent_items = logging_mod.getRecentlyWatched(logs_database, allocator, username, 20) catch &[_]logging_mod.RecentlyWatchedItem{};
    defer allocator.free(recent_items);

    var recent_cards_buf = std.ArrayList(u8).empty;
    defer recent_cards_buf.deinit(allocator);

    var recent_count: usize = 0;

    const cat = database.catalog orelse return "";

    for (recent_items) |item| {
        if (item.media_type == .movie) {
            if (cat.getMovieById(allocator, item.item_id) catch null) |mov| {
                defer {
                    var mut = mov;
                    mut.deinit(allocator);
                }
                if (mov.is_present) {
                    var progress_pct: ?f64 = null;
                    if (item.duration > 0) {
                        progress_pct = (item.position / item.duration) * 100.0;
                    }

                    recent_count += 1;
                    try cards.appendMovieCard(&recent_cards_buf, allocator, item.item_id, null, mov.clean_name, mov.title, mov.poster_path, null, progress_pct, false);
                }
            }
        } else if (item.media_type == .episode) {
            if (cat.getEpisodeById(allocator, item.item_id) catch null) |ep| {
                defer {
                    var mut = ep;
                    mut.deinit(allocator);
                }
                if (ep.is_present) {
                    if (cat.getShowById(allocator, ep.show_id) catch null) |sh| {
                        defer {
                            var mut_sh = sh;
                            mut_sh.deinit(allocator);
                        }
                        if (sh.is_present) {
                            const basename = std.fs.path.basename(ep.file_path);
                            const ep_display_name = ep.title orelse basename;

                            var ep_badge_buf: [32]u8 = undefined;
                            const ep_badge = std.fmt.bufPrint(&ep_badge_buf, "S{d}:E{d}", .{ ep.season, ep.episode }) catch "TV";

                            var progress_pct: ?f64 = null;
                            if (item.duration > 0) {
                                progress_pct = (item.position / item.duration) * 100.0;
                            }

                            recent_count += 1;
                            try cards.appendEpisodeRecentCard(&recent_cards_buf, allocator, item.item_id, sh.title, ep_display_name, sh.poster_path, ep_badge, progress_pct);
                        }
                    }
                }
            }
        }
    }

    if (recent_count > 0) {
        try recently_watched_section_buf.appendSlice(allocator,
            \\<div id="recently-watched-section" class="media-section" style="margin-top: 40px;">
            \\    <h2 class="section-title">Recently Watched</h2>
            \\    <div class="horizontal-scroll-row">
        );
        try recently_watched_section_buf.appendSlice(allocator, recent_cards_buf.items);
        try recently_watched_section_buf.appendSlice(allocator,
            \\    </div>
            \\</div>
        );
    }

    const admin_link_html = if (is_admin)
        \\<a href="/admin" class="admin-btn">
        \\    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="18" height="18">
        \\        <path d="M12 15a3 3 0 100-6 3 3 0 000 6z"/>
        \\        <path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-2 2 2 2 0 01-2-2v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83 0 2 2 0 010-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 01-2-2 2 2 0 012-2h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 010-2.83 2 2 0 012.83 0l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V3a2 2 0 012-2 2 2 0 012 2v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 0 2 2 0 010 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9a1.65 1.65 0 001.51 1H21a2 2 0 012 2 2 2 0 01-2 2h-.09a1.65 1.65 0 00-1.51 1z"/>
        \\    </svg>
        \\    Admin
        \\</a>
    else
        "";

    return template_engine.render(allocator, @embedFile("../templates/catalog.html"), .{
        .INLINE_CSS = global_css,
        .LIBRARY_CARDS = cards_buf.items,
        .RECENTLY_WATCHED_SECTION = recently_watched_section_buf.items,
        .ADMIN_LINK = admin_link_html,
        .APP_VERSION = build_options.version,
    });
}
