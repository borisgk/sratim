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

    var html_buf = std.ArrayList(u8).empty;
    errdefer html_buf.deinit(allocator);

    try html_buf.appendSlice(allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Sratim Catalog</title>
        \\    <style>
        \\        body { background: #111; color: #eee; font-family: sans-serif; padding: 20px; }
        \\        h1 { color: #fff; text-align: center; }
        \\        ul { list-style: none; padding: 0; max-width: 800px; margin: 0 auto; }
        \\        li { margin-bottom: 10px; padding: 15px; background: #222; border-radius: 5px; }
        \\        a { color: #4af; text-decoration: none; font-size: 1.1em; display: block; }
        \\        a:hover { color: #8cf; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>Movie Catalog</h1>
        \\    <ul>
        \\
    );

    // Collect and append each video file to the HTML
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and isVideoFile(entry.basename)) {
            try html_buf.appendSlice(allocator, "        <li><a href=\"/player?file=");
            try writePercentEncoded(&html_buf, allocator, entry.path);
            try html_buf.appendSlice(allocator, "\">");
            try html_buf.appendSlice(allocator, entry.path);
            try html_buf.appendSlice(allocator, "</a></li>\n");
        }
    }

    try html_buf.appendSlice(allocator,
        \\    </ul>
        \\</body>
        \\</html>
        \\
    );

    return try html_buf.toOwnedSlice(allocator);
}

