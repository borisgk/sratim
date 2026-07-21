const std = @import("std");
const template_engine = @import("../core/template.zig");
const minify = @import("../core/minify.zig");
const db_mod = @import("../db/db.zig");
const library_mod = @import("../db/library.zig");
const logging_mod = @import("../db/logging.zig");
const metadata_mod = @import("../db/metadata.zig");
const global_css: []const u8 = minify.minifyCss(@embedFile("style.css"));

const video_extensions = [_][]const u8{ ".mkv", ".mp4", ".avi", ".ts", ".webm", ".mov" };

fn isVideoFile(basename: []const u8) bool {
    for (video_extensions) |ext| {
        if (std.mem.endsWith(u8, basename, ext)) return true;
    }
    return false;
}

/// Percent-encodes a path for use in an HTML href attribute.
fn writePercentEncoded(list: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            ' ' => try list.appendSlice(allocator, "%20"),
            '#' => try list.appendSlice(allocator, "%23"),
            '?' => try list.appendSlice(allocator, "%3F"),
            '&' => try list.appendSlice(allocator, "%26"),
            '%' => try list.appendSlice(allocator, "%25"),
            '"' => try list.appendSlice(allocator, "%22"),
            '<' => try list.appendSlice(allocator, "%3C"),
            '>' => try list.appendSlice(allocator, "%3E"),
            '\''=> try list.appendSlice(allocator, "%27"),
            else => try list.append(allocator, ch),
        }
    }
}

/// Escapes HTML special characters for safe injection into text content.
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

/// Generates the HTML catalog of libraries.
pub fn generateHtml(allocator: std.mem.Allocator, database: *db_mod.Database) ![]u8 {
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
            const icon_svg = switch (lib.lib_type) {
                .Movies => 
                    \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="28" height="28">
                    \\    <circle cx="12" cy="12" r="10"></circle>
                    \\    <circle cx="12" cy="12" r="2"></circle>
                    \\    <circle cx="12" cy="7" r="1.5"></circle>
                    \\    <circle cx="12" cy="17" r="1.5"></circle>
                    \\    <circle cx="7" cy="12" r="1.5"></circle>
                    \\    <circle cx="17" cy="12" r="1.5"></circle>
                    \\</svg>
                ,
                .Shows => 
                    \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="28" height="28">
                    \\    <rect x="2" y="7" width="20" height="15" rx="2" ry="2"></rect>
                    \\    <polyline points="17 2 12 7 7 2"></polyline>
                    \\</svg>
                ,
                .Other => 
                    \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="28" height="28">
                    \\    <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path>
                    \\</svg>
                ,
            };

            const card_start = try std.fmt.allocPrint(allocator, "            <a href=\"/library?id={d}\" class=\"library-card\">\n", .{lib.id});
            defer allocator.free(card_start);
            try cards_buf.appendSlice(allocator, card_start);

            try cards_buf.appendSlice(allocator, "                <div class=\"card-top\">\n                    <div class=\"icon-wrapper\">\n                        ");
            try cards_buf.appendSlice(allocator, icon_svg);
            try cards_buf.appendSlice(allocator, "\n                    </div>\n                    <div class=\"card-info\">\n                        <h3 class=\"library-title\">");
            try escapeHtml(&cards_buf, allocator, lib.name);
            try cards_buf.appendSlice(allocator, "</h3>\n                        <span class=\"library-path\">");
            try escapeHtml(&cards_buf, allocator, lib.path);
            try cards_buf.appendSlice(allocator, "</span>\n                    </div>\n                </div>\n                <div class=\"card-bottom\">\n                    <span class=\"type-badge\">");
            try cards_buf.appendSlice(allocator, lib.lib_type.toString());
            try cards_buf.appendSlice(allocator, "</span>\n                    <span class=\"browse-pill\">Browse</span>\n                </div>\n            </a>\n");
        }
    }

    return template_engine.render(allocator, @embedFile("templates/catalog.html"), .{
        .INLINE_CSS = global_css,
        .LIBRARY_CARDS = cards_buf.items,
    });
}

pub fn generateLibraryContentHtml(allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, logs_database: *db_mod.Database, library_id: i64, username: []const u8) !?[]u8 {
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

    const progress_list = logging_mod.getProgressForUser(logs_database, allocator, username) catch &[_]logging_mod.ProgressInfo{};
    defer {
        allocator.free(progress_list);
    }

    var cards_buf = std.ArrayList(u8).empty;
    defer cards_buf.deinit(allocator);

    if (lib.lib_type == .Shows) {
        var stmt = try database.prepare(
            \\SELECT id, title, poster_path 
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

            try cards_buf.appendSlice(allocator, "    <div class=\"movie-item\">\n");
            if (poster_path_opt != null and poster_path_opt.?.len > 0) {
                try cards_buf.appendSlice(allocator, "        <div class=\"movie-card has-poster\" data-name=\"");
            } else {
                try cards_buf.appendSlice(allocator, "        <div class=\"movie-card\" data-name=\"");
            }
            try escapeHtml(&cards_buf, allocator, title);
            try cards_buf.appendSlice(allocator, "\">\n");
            
            if (poster_path_opt != null and poster_path_opt.?.len > 0) {
                try cards_buf.appendSlice(allocator, "            <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
                try cards_buf.appendSlice(allocator, poster_path_opt.?);
                try cards_buf.appendSlice(allocator, "\">\n");
            }

            // No quick actions for shows, just the link to the show details
            const dropdown_content = try std.fmt.allocPrint(allocator,
                \\            <a href="/show?id={d}" class="play-link"></a>
                \\            <div class="card-content">
                \\                <div class="card-top">
                \\                    <div class="icon-wrapper">
                \\                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24">
                \\                            <rect x="2" y="7" width="20" height="15" rx="2" ry="2"></rect>
                \\                            <polyline points="17 2 12 7 7 2"></polyline>
                \\                        </svg>
                \\                    </div>
                \\                </div>
                \\            </div>
                \\
            , .{ show_id });
            defer allocator.free(dropdown_content);
            try cards_buf.appendSlice(allocator, dropdown_content);

            try cards_buf.appendSlice(allocator, "        </div>\n        <h3 class=\"movie-title\">");
            try escapeHtml(&cards_buf, allocator, title);
            try cards_buf.appendSlice(allocator, "</h3>\n    </div>\n");
        }
    } else {
        var stmt = try database.prepare(
            \\SELECT id, file_path, clean_name, title, poster_path 
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

        const display_title = if (title_opt) |t| t else clean_name;

        var progress_pct: ?f64 = null;
        for (progress_list) |item| {
            if (item.movie_id == movie_id) {
                if (item.duration > 0) {
                    progress_pct = (item.position / item.duration) * 100.0;
                }
                break;
            }
        }

        try cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n");
        if (poster_path_opt != null and poster_path_opt.?.len > 0) {
            try cards_buf.appendSlice(allocator, "            <div class=\"movie-card has-poster\" data-name=\"");
        } else {
            try cards_buf.appendSlice(allocator, "            <div class=\"movie-card\" data-name=\"");
        }
        try escapeHtml(&cards_buf, allocator, file_path);
        try cards_buf.appendSlice(allocator, "\">\n");
        
        if (poster_path_opt != null and poster_path_opt.?.len > 0) {
            try cards_buf.appendSlice(allocator, "                <img class=\"poster-img\" loading=\"lazy\" alt=\"poster\" src=\"/images/posters/w185");
            try cards_buf.appendSlice(allocator, poster_path_opt.?);
            try cards_buf.appendSlice(allocator, "\">\n");
        }
        try cards_buf.appendSlice(allocator, "            <button class=\"context-menu-btn\" title=\"Actions\">\n                <svg viewBox=\"0 0 24 24\" fill=\"currentColor\" width=\"20\" height=\"20\">\n                    <circle cx=\"12\" cy=\"5\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"12\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"19\" r=\"2\"/>\n                </svg>\n            </button>\n            <div class=\"context-dropdown\">\n");
        const dropdown_content = try std.fmt.allocPrint(allocator,
            \\                <button class="dropdown-item lookup-btn" data-id="{d}">Lookup Metadata</button>
            \\                <button class="dropdown-item reset-btn" data-id="{d}">Reset Progress</button>
            \\                <button class="dropdown-item watch-btn" data-id="{d}">Mark as Watched</button>
            \\                <a class="dropdown-item" style="text-decoration: none;" href="/player?id={d}">Quick Play</a>
            \\            </div>
            \\
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
        , .{ movie_id, movie_id, movie_id, movie_id, movie_id });
        defer allocator.free(dropdown_content);
        try cards_buf.appendSlice(allocator, dropdown_content);

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
        try escapeHtml(&cards_buf, allocator, display_title);
        try cards_buf.appendSlice(allocator, "</h3>\n    </div>\n");
    }
    }

    return try template_engine.render(allocator, @embedFile("templates/library_view.html"), .{
        .INLINE_CSS = global_css,
        .LIBRARY_NAME = lib.name,
        .LIBRARY_PATH = lib.path,
        .MOVIE_CARDS = cards_buf.items,
    });
}

pub fn generateDetailsHtml(
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    movie_id: i64,
    username: []const u8,
) ![]u8 {
    const template = @embedFile("templates/details.html");
    const info_opt = try metadata_mod.getMovieInfoById(database, allocator, movie_id);
    if (info_opt == null) return error.MovieNotFound;
    const info = info_opt.?;
    defer allocator.free(info.file_path);

    const meta = try metadata_mod.getMetadataById(database, allocator, movie_id);
    defer if (meta) |m| {
        allocator.free(m.file_path);
        allocator.free(m.title);
        if (m.overview) |ov| allocator.free(ov);
        if (m.poster_path) |pp| allocator.free(pp);
        if (m.backdrop_path) |bp| allocator.free(bp);
        if (m.release_date) |rd| allocator.free(rd);
    };

    var title: []const u8 = std.fs.path.basename(info.file_path);
    const lib_id_str = try std.fmt.allocPrint(allocator, "{d}", .{info.library_id});
    defer allocator.free(lib_id_str);
    var overview: []const u8 = "No description available.";
    var release_date: []const u8 = "";
    var poster_style_buf = std.ArrayList(u8).empty;
    defer poster_style_buf.deinit(allocator);
    var backdrop_style_buf = std.ArrayList(u8).empty;
    defer backdrop_style_buf.deinit(allocator);

    try backdrop_style_buf.appendSlice(allocator, "background-color: #0b0f19;");

    if (meta) |m| {
        if (m.title.len > 0) title = m.title;
        if (m.overview) |ov| overview = ov;
        if (m.release_date) |rd| release_date = rd;
        if (m.poster_path) |pp| {
            try poster_style_buf.appendSlice(allocator, "background-image: url('/images/posters/original");
            try poster_style_buf.appendSlice(allocator, pp);
            try poster_style_buf.appendSlice(allocator, "');");
        }
        if (m.backdrop_path) |bp| {
            backdrop_style_buf.clearRetainingCapacity();
            try backdrop_style_buf.appendSlice(allocator, "background-image: url('/images/backdrops/original");
            try backdrop_style_buf.appendSlice(allocator, bp);
            try backdrop_style_buf.appendSlice(allocator, "');");
        }
    }

    var play_url = std.ArrayList(u8).empty;
    defer play_url.deinit(allocator);
    const movie_id_str = try std.fmt.allocPrint(allocator, "/player?id={d}", .{movie_id});
    defer allocator.free(movie_id_str);
    try play_url.appendSlice(allocator, movie_id_str);

    var resume_btn_buf = std.ArrayList(u8).empty;
    defer resume_btn_buf.deinit(allocator);

    const resume_pos = logging_mod.getPlaybackProgress(logs_database, username, movie_id) catch 0.0;
    if (resume_pos > 0.0) {
        const resume_btn = try std.fmt.allocPrint(allocator, 
            \\                    <a href="{s}" class="play-btn-large resume-btn">
            \\                        <svg viewBox="0 0 24 24" fill="currentColor" width="28" height="28">
            \\                            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z" />
            \\                        </svg>
            \\                        Resume
            \\                    </a>
        , .{ play_url.items });
        defer allocator.free(resume_btn);
        try resume_btn_buf.appendSlice(allocator, resume_btn);
    }

    try play_url.appendSlice(allocator, "&start=0");

    var html = std.ArrayList(u8).empty;
    defer html.deinit(allocator);
    try html.appendSlice(allocator, template);

    // Replace placeholders
    const replacements = &[_][2][]const u8{
        .{ "__INLINE_CSS__", global_css },
        .{ "__TITLE__", title },
        .{ "__OVERVIEW__", overview },
        .{ "__RELEASE_DATE__", release_date },
        .{ "__POSTER_STYLE__", poster_style_buf.items },
        .{ "__BACKDROP_STYLE__", backdrop_style_buf.items },
        .{ "__PLAY_URL__", play_url.items },
        .{ "__RESUME_BTN__", resume_btn_buf.items },
        .{ "__LIB_ID__", lib_id_str },
    };

    var current_html = html.items;
    for (replacements) |rep| {
        const placeholder = rep[0];
        const value = rep[1];
        if (std.mem.indexOf(u8, current_html, placeholder)) |_| {
            const replaced = try std.mem.replaceOwned(u8, allocator, current_html, placeholder, value);
            // If it's not the first pass, free the old one
            if (current_html.ptr != html.items.ptr) {
                allocator.free(current_html);
            }
            current_html = replaced;
        }
    }

    if (current_html.ptr == html.items.ptr) {
        return html.toOwnedSlice(allocator);
    } else {
        return current_html;
    }
}
