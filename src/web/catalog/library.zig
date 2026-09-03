const std = @import("std");
const template_engine = @import("../../core/template.zig");
const db_mod = @import("../../db/db.zig");
const library_mod = @import("../../db/library.zig");
const logging_mod = @import("../../db/logging.zig");
const cards = @import("cards.zig");

const global_css: []const u8 = @embedFile("../style.css");

pub fn generateLibraryContentHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    library_id: i64,
    username: []const u8,
    is_admin: bool,
) !?[]u8 {
    _ = io;
    const lib_opt = try library_mod.getLibraryById(database, allocator, library_id);
    if (lib_opt == null) return null;

    const lib = lib_opt.?;
    defer {
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    const rescan_btn_html = if (is_admin)
        try std.fmt.allocPrint(allocator,
            \\<button id="rescan-lib-btn" class="rescan-btn" data-id="{d}">
            \\    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="18" height="18">
            \\        <path d="M21.5 2v6h-6M2.14 15.57a10 10 0 1 0 2.83-9.57l5.53 5.53" stroke-linecap="round" stroke-linejoin="round"/>
            \\    </svg>
            \\    Rescan Library
            \\</button>
        , .{lib.id})
    else
        "";
    defer if (is_admin) allocator.free(rescan_btn_html);

    const progress_list = logging_mod.getProgressForUser(logs_database, allocator, username) catch &[_]logging_mod.ProgressInfo{};
    defer allocator.free(progress_list);

    var cards_buf = std.ArrayList(u8).empty;
    defer cards_buf.deinit(allocator);

    var recently_added_section_buf = std.ArrayList(u8).empty;
    defer recently_added_section_buf.deinit(allocator);

    const cat = database.catalog orelse return null;

    if (lib.lib_type == .Shows) {
        const shows = try cat.getShowsByLibrary(allocator, lib.id);
        defer {
            for (shows) |*s| {
                var mut = s.*;
                mut.deinit(allocator);
            }
            allocator.free(shows);
        }

        for (shows) |s| {
            try cards.appendShowCard(&cards_buf, allocator, s.id, s.title, s.poster_path, s.tmdb_id, is_admin);
        }
    } else {
        const recent_movies = try cat.getRecentMoviesByLibrary(allocator, lib.id, 20);
        defer {
            for (recent_movies) |*m| {
                var mut = m.*;
                mut.deinit(allocator);
            }
            allocator.free(recent_movies);
        }

        var recent_cards_buf = std.ArrayList(u8).empty;
        defer recent_cards_buf.deinit(allocator);

        for (recent_movies) |m| {
            var progress_pct: ?f64 = null;
            for (progress_list) |item| {
                if (item.movie_id == m.id) {
                    if (item.duration > 0) {
                        progress_pct = (item.position / item.duration) * 100.0;
                    }
                    break;
                }
            }

            try cards.appendMovieCard(&recent_cards_buf, allocator, m.id, m.file_path, m.clean_name, m.title, m.poster_path, m.tmdb_id, progress_pct, is_admin);
        }

        if (recent_movies.len > 0) {
            try recently_added_section_buf.appendSlice(allocator,
                \\<div id="recently-added-section" class="media-section">
                \\    <h2 class="section-title">Recently Added</h2>
                \\    <div class="horizontal-scroll-row">
            );
            try recently_added_section_buf.appendSlice(allocator, recent_cards_buf.items);
            try recently_added_section_buf.appendSlice(allocator,
                \\    </div>
                \\</div>
                \\<div class="media-section-header">
                \\    <h2 class="section-title">All Movies</h2>
                \\</div>
            );
        }

        const all_movies = try cat.getMoviesByLibrary(allocator, lib.id);
        defer {
            for (all_movies) |*m| {
                var mut = m.*;
                mut.deinit(allocator);
            }
            allocator.free(all_movies);
        }

        for (all_movies) |m| {
            var progress_pct: ?f64 = null;
            for (progress_list) |item| {
                if (item.movie_id == m.id) {
                    if (item.duration > 0) {
                        progress_pct = (item.position / item.duration) * 100.0;
                    }
                    break;
                }
            }

            try cards.appendMovieCard(&cards_buf, allocator, m.id, m.file_path, m.clean_name, m.title, m.poster_path, m.tmdb_id, progress_pct, is_admin);
        }
    }

    return try template_engine.render(allocator, @embedFile("../templates/library_view.html"), .{
        .INLINE_CSS = global_css,
        .LIBRARY_NAME = lib.name,
        .LIBRARY_PATH = lib.path,
        .RECENTLY_ADDED_SECTION = recently_added_section_buf.items,
        .MOVIE_CARDS = cards_buf.items,
        .RESCAN_BTN = rescan_btn_html,
    });
}
