const std = @import("std");
const template_engine = @import("../core/template.zig");
const db_mod = @import("../db/db.zig");
const library_mod = @import("../db/library.zig");
const logging_mod = @import("../db/logging.zig");
const metadata_mod = @import("../db/metadata.zig");

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
        .LIBRARY_CARDS = cards_buf.items,
    });
}

pub fn generateLibraryContentHtml(allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, logs_database: *db_mod.Database, library_id: i64, username: []const u8) !?[]u8 {
    const lib_opt = try library_mod.getLibraryById(database, allocator, library_id);
    if (lib_opt == null) return null;

    const lib = lib_opt.?;
    defer {
        allocator.free(lib.name);
        allocator.free(lib.path);
        allocator.free(lib.metadata_language);
        if (lib.ignore_patterns) |pat| allocator.free(pat);
    }

    const progress_list = logging_mod.getLibraryProgressForUser(logs_database, allocator, username, library_id) catch &[_]logging_mod.ProgressInfo{};
    defer {
        for (progress_list) |item| {
            allocator.free(item.file_path);
        }
        allocator.free(progress_list);
    }

    var dir = std.Io.Dir.cwd().openDir(io, lib.path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open library path {s}: {}\n", .{lib.path, err});
        return error.LibraryPathNotFound;
    };
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var cards_buf = std.ArrayList(u8).empty;
    defer cards_buf.deinit(allocator);

    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and isVideoFile(entry.basename)) {
            const ext = std.fs.path.extension(entry.basename);
            const ext_idx = entry.basename.len - ext.len;
            const clean_name = entry.basename[0..ext_idx];

            const meta = try metadata_mod.getMetadata(database, allocator, lib.id, entry.path);

            var title_buf = std.ArrayList(u8).empty;
            defer title_buf.deinit(allocator);
            if (meta) |m| {
                try title_buf.appendSlice(allocator, m.title);
                if (m.release_date) |d| {
                    if (d.len >= 4) {
                        try title_buf.appendSlice(allocator, " (");
                        try title_buf.appendSlice(allocator, d[0..4]);
                        try title_buf.appendSlice(allocator, ")");
                    }
                }
            } else {
                try title_buf.appendSlice(allocator, clean_name);
            }

            var progress_pct: ?f64 = null;
            for (progress_list) |item| {
                if (std.mem.eql(u8, item.file_path, entry.path)) {
                    if (item.duration > 0) {
                        progress_pct = (item.position / item.duration) * 100.0;
                    }
                    break;
                }
            }

            // In /player, the file path parameter should be scoped. Wait! Let's pass the relative path
            // from the library. Or pass the file ID? For now, we will pass library_id and path to player/stream
            // e.g. /player?library=1&file=path/to/movie.mp4. This is much safer than absolute paths!
            if (meta != null and meta.?.poster_path != null and meta.?.poster_path.?.len > 0) {
                try cards_buf.appendSlice(allocator, "        <div class=\"movie-card has-poster\" style=\"background-image: url('https://image.tmdb.org/t/p/w500");
                try cards_buf.appendSlice(allocator, meta.?.poster_path.?);
                try cards_buf.appendSlice(allocator, "')\" data-name=\"");
            } else {
                try cards_buf.appendSlice(allocator, "        <div class=\"movie-card\" data-name=\"");
            }
            try escapeHtml(&cards_buf, allocator, entry.path);
            try cards_buf.appendSlice(allocator, "\">\n            <button class=\"context-menu-btn\" title=\"Actions\">\n                <svg viewBox=\"0 0 24 24\" fill=\"currentColor\" width=\"20\" height=\"20\">\n                    <circle cx=\"12\" cy=\"5\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"12\" r=\"2\"/>\n                    <circle cx=\"12\" cy=\"19\" r=\"2\"/>\n                </svg>\n            </button>\n            <div class=\"context-dropdown\">\n                <button class=\"dropdown-item lookup-btn\" data-file=\"");
            try escapeHtml(&cards_buf, allocator, entry.path);
            const lookup_mid = try std.fmt.allocPrint(allocator, "\" data-library=\"{d}\">Lookup Metadata</button>\n                <button class=\"dropdown-item reset-btn\" data-file=\"", .{lib.id});
            defer allocator.free(lookup_mid);
            try cards_buf.appendSlice(allocator, lookup_mid);
            try escapeHtml(&cards_buf, allocator, entry.path);
            const dropdown_middle = try std.fmt.allocPrint(allocator, "\" data-library=\"{d}\">Reset Progress</button>\n                <button class=\"dropdown-item watch-btn\" data-file=\"", .{lib.id});
            defer allocator.free(dropdown_middle);
            try cards_buf.appendSlice(allocator, dropdown_middle);
            try escapeHtml(&cards_buf, allocator, entry.path);
            const dropdown_end = try std.fmt.allocPrint(allocator, "\" data-library=\"{d}\">Mark as Watched</button>\n            </div>\n\n", .{lib.id});
            defer allocator.free(dropdown_end);
            try cards_buf.appendSlice(allocator, dropdown_end);

            try cards_buf.appendSlice(allocator, "            <a href=\"/player?library=");
            const lib_id_str = try std.fmt.allocPrint(allocator, "{d}", .{lib.id});
            defer allocator.free(lib_id_str);
            try cards_buf.appendSlice(allocator, lib_id_str);
            try cards_buf.appendSlice(allocator, "&file=");
            try writePercentEncoded(&cards_buf, allocator, entry.path);
            try cards_buf.appendSlice(allocator, "\" class=\"play-link\"></a>\n\n            <div class=\"card-content\">\n                <div class=\"card-top\">\n                    <div class=\"icon-wrapper\">\n                        <svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" width=\"24\" height=\"24\">\n                            <path d=\"M15 10l5-3.07v10.14L15 14v-4z\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n                            <rect x=\"4\" y=\"6\" width=\"11\" height=\"12\" rx=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n                        </svg>\n                    </div>\n                    <h3 class=\"movie-title\">");
            try escapeHtml(&cards_buf, allocator, title_buf.items);
            try cards_buf.appendSlice(allocator, "</h3>\n                </div>\n                <div class=\"card-bottom\">\n                    <div class=\"metadata\">\n                        <span class=\"ext-badge\">");
            const ext_no_dot = if (ext.len > 0) ext[1..] else ext;
            try escapeHtml(&cards_buf, allocator, ext_no_dot);
            try cards_buf.appendSlice(allocator, "</span>\n                    </div>\n                    <span class=\"watch-pill\">Watch</span>\n                </div>\n            </div>\n");

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

            try cards_buf.appendSlice(allocator, "        </div>\n");
        }
    }

    return try template_engine.render(allocator, @embedFile("templates/library_view.html"), .{
        .LIBRARY_NAME = lib.name,
        .LIBRARY_PATH = lib.path,
        .MOVIE_CARDS = cards_buf.items,
    });
}
