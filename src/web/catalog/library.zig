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

    if (lib.lib_type == .Shows) {
        var stmt = try database.prepare(
            \\SELECT id, title, poster_path, tmdb_id 
            \\FROM shows
            \\WHERE library_id = ?1 AND is_present = 1
            \\ORDER BY 
            \\    CASE 
            \\        WHEN title LIKE 'The %' THEN SUBSTR(title, 5)
            \\        WHEN title LIKE 'A %' THEN SUBSTR(title, 3)
            \\        WHEN title LIKE 'An %' THEN SUBSTR(title, 4)
            \\        ELSE title
            \\    END COLLATE NOCASE ASC;
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, lib.id);

        while ((try stmt.step()) == .row) {
            const show_id = stmt.columnInt64(0);
            const title = stmt.columnText(1).?;
            const poster_path_opt = stmt.columnText(2);
            const tmdb_id_val = stmt.columnText(3);
            const tmdb_id = if (tmdb_id_val != null) stmt.columnInt64(3) else null;

            try cards.appendShowCard(&cards_buf, allocator, show_id, title, poster_path_opt, tmdb_id, is_admin);
        }
    } else {
        var recent_stmt = try database.prepare(
            \\SELECT id, file_path, clean_name, title, poster_path, tmdb_id 
            \\FROM movies
            \\WHERE library_id = ?1 AND is_present = 1
            \\ORDER BY id DESC
            \\LIMIT 20;
        );
        defer recent_stmt.finalize();
        try recent_stmt.bindInt64(1, lib.id);

        var recent_cards_buf = std.ArrayList(u8).empty;
        defer recent_cards_buf.deinit(allocator);

        var recent_count: usize = 0;
        while ((try recent_stmt.step()) == .row) {
            recent_count += 1;
            const movie_id = recent_stmt.columnInt64(0);
            const file_path = recent_stmt.columnText(1).?;
            const clean_name = recent_stmt.columnText(2).?;
            const title_opt = recent_stmt.columnText(3);
            const poster_path_opt = recent_stmt.columnText(4);
            const tmdb_id_val = recent_stmt.columnText(5);
            const tmdb_id = if (tmdb_id_val != null) recent_stmt.columnInt64(5) else null;

            var progress_pct: ?f64 = null;
            for (progress_list) |item| {
                if (item.movie_id == movie_id) {
                    if (item.duration > 0) {
                        progress_pct = (item.position / item.duration) * 100.0;
                    }
                    break;
                }
            }

            try cards.appendMovieCard(&recent_cards_buf, allocator, movie_id, file_path, clean_name, title_opt, poster_path_opt, tmdb_id, progress_pct, is_admin);
        }

        if (recent_count > 0) {
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

        var stmt = try database.prepare(
            \\SELECT id, file_path, clean_name, title, poster_path, tmdb_id 
            \\FROM movies
            \\WHERE library_id = ?1 AND is_present = 1
            \\ORDER BY 
            \\    CASE 
            \\        WHEN COALESCE(title, clean_name) LIKE 'The %' THEN SUBSTR(COALESCE(title, clean_name), 5)
            \\        WHEN COALESCE(title, clean_name) LIKE 'A %' THEN SUBSTR(COALESCE(title, clean_name), 3)
            \\        WHEN COALESCE(title, clean_name) LIKE 'An %' THEN SUBSTR(COALESCE(title, clean_name), 4)
            \\        ELSE COALESCE(title, clean_name)
            \\    END COLLATE NOCASE ASC;
        );
        defer stmt.finalize();
        try stmt.bindInt64(1, lib.id);

        while ((try stmt.step()) == .row) {
            const movie_id = stmt.columnInt64(0);
            const file_path = stmt.columnText(1).?;
            const clean_name = stmt.columnText(2).?;
            const title_opt = stmt.columnText(3);
            const poster_path_opt = stmt.columnText(4);
            const tmdb_id_val = stmt.columnText(5);
            const tmdb_id = if (tmdb_id_val != null) stmt.columnInt64(5) else null;

            var progress_pct: ?f64 = null;
            for (progress_list) |item| {
                if (item.movie_id == movie_id) {
                    if (item.duration > 0) {
                        progress_pct = (item.position / item.duration) * 100.0;
                    }
                    break;
                }
            }

            try cards.appendMovieCard(&cards_buf, allocator, movie_id, file_path, clean_name, title_opt, poster_path_opt, tmdb_id, progress_pct, is_admin);
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
