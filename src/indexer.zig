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
        \\        li { background: white; margin: 0.5rem 0; padding: 1rem; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); display: flex; justify-content: space-between; align-items: center; }
        \\        .info-icon { cursor: pointer; color: #3498db; font-weight: bold; border: 1px solid #3498db; border-radius: 50%; width: 24px; height: 24px; display: inline-flex; align-items: center; justify-content: center; font-size: 0.8rem; }
        \\        .info-icon:hover { background: #3498db; color: white; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>Available MKV Files</h1>
        \\    <ul>
        \\
    );

    var walker = try dir.walk(allocator);
    defer walker.deinit();
    
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".mkv")) {
            count += 1;
            
            // Allocate string for the relative path
            const rel_path = try allocator.dupe(u8, entry.path);
            defer allocator.free(rel_path);
            
            try list.appendSlice(allocator, "        <li><a href=\"/player?file=");
            
            // The path might contain spaces, we should URL encode it, but for now we just write it exactly as we did before.
            // A more robust URL encoding could be added, but for simple paths it works.
            
            // URL encoding basic implementation
            for (rel_path) |c| {
                if (c == ' ') {
                    try list.appendSlice(allocator, "%20");
                } else if (c == '&') {
                    try list.appendSlice(allocator, "%26");
                } else {
                    try list.append(allocator, c);
                }
            }
            
            try list.appendSlice(allocator, "\" style=\"text-decoration:none; color:#2c3e50; font-weight:bold;\">");
            
            // HTML escape name
            for (rel_path) |c| {
                if (c == '<') try list.appendSlice(allocator, "&lt;")
                else if (c == '>') try list.appendSlice(allocator, "&gt;")
                else try list.append(allocator, c);
            }
            
            try list.appendSlice(allocator, "</a><a href=\"/info?file=");
            for (rel_path) |c| {
                if (c == ' ') {
                    try list.appendSlice(allocator, "%20");
                } else if (c == '&') {
                    try list.appendSlice(allocator, "%26");
                } else {
                    try list.append(allocator, c);
                }
            }
            try list.appendSlice(allocator, "\" class=\"info-icon\" title=\"Information\" style=\"text-decoration:none;\">i</a></li>\n");
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
