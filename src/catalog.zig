const std = @import("std");

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

/// Generates an HTML catalog of all video files within the working folder.
pub fn generateHtml(allocator: std.mem.Allocator, io: std.Io, working_folder: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, working_folder, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var cards_buf = std.ArrayList(u8).empty;
    defer cards_buf.deinit(allocator);

    // Collect and append each video file to the card buffer
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and isVideoFile(entry.basename)) {
            const ext = std.fs.path.extension(entry.basename);
            const ext_idx = entry.basename.len - ext.len;
            const clean_name = entry.basename[0..ext_idx];

            try cards_buf.appendSlice(allocator, "        <a href=\"/player?file=");
            try writePercentEncoded(&cards_buf, allocator, entry.path);
            try cards_buf.appendSlice(allocator, "\" class=\"movie-card\" data-name=\"");
            try escapeHtml(&cards_buf, allocator, entry.path);
            try cards_buf.appendSlice(allocator, "\">\n            <div class=\"card-top\">\n                <div class=\"icon-wrapper\">\n                    <svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" width=\"24\" height=\"24\">\n                        <path d=\"M15 10l5-3.07v10.14L15 14v-4z\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n                        <rect x=\"4\" y=\"6\" width=\"11\" height=\"12\" rx=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n                    </svg>\n                </div>\n                <h3 class=\"movie-title\">");
            try escapeHtml(&cards_buf, allocator, clean_name);
            try cards_buf.appendSlice(allocator, "</h3>\n            </div>\n            <div class=\"card-bottom\">\n                <div class=\"metadata\">\n                    <span class=\"ext-badge\">");
            const ext_no_dot = if (ext.len > 0) ext[1..] else ext;
            try escapeHtml(&cards_buf, allocator, ext_no_dot);
            try cards_buf.appendSlice(allocator, "</span>\n                </div>\n                <span class=\"watch-pill\">Watch</span>\n            </div>\n        </a>\n");
        }
    }

    const template = @embedFile("catalog.html");

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "__MOVIE_CARDS__")) {
            try out.appendSlice(allocator, cards_buf.items);
            i += "__MOVIE_CARDS__".len;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }

    return try out.toOwnedSlice(allocator);
}
