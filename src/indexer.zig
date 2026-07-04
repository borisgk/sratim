const std = @import("std");

pub fn generateHtmlListing(allocator: std.mem.Allocator, io: std.Io, folder_path: []const u8) ![]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, folder_path, .{ .iterate = true });
    defer dir.close(io);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, 
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>MKV Player - Files</title>
        \\    <style>
        \\        body { font-family: sans-serif; padding: 2rem; background: #f4f4f9; color: #333; }
        \\        h1 { color: #2c3e50; }
        \\        ul { list-style: none; padding: 0; }
        \\        li { background: white; margin: 0.5rem 0; padding: 1rem; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>Available MKV Files</h1>
        \\    <ul>
        \\
    );

    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".mkv")) {
            count += 1;
            try list.appendSlice(allocator, "        <li>");
            try list.appendSlice(allocator, entry.name);
            try list.appendSlice(allocator, "</li>\n");
        }
    }

    if (count == 0) {
        try list.appendSlice(allocator, "        <li>No MKV files found in this directory.</li>\n");
    }

    try list.appendSlice(allocator, 
        \\    </ul>
        \\</body>
        \\</html>
    );

    return list.toOwnedSlice(allocator);
}
