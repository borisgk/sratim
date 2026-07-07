const std = @import("std");

/// Generates an HTML catalog of all .mkv files within the working folder.
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

    // Collect and append each MKV file to the HTML
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".mkv")) {
            try html_buf.print(allocator, "        <li><a href=\"/player?file={s}\">{s}</a></li>\n", .{ entry.path, entry.path });
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
