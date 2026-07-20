const std = @import("std");
const c = @import("../../core/c.zig").c;

/// Lists subdirectories of a given path for the file browser modal.
pub fn handleApiBrowse(request: *std.http.Server.Request, allocator: std.mem.Allocator, io: std.Io) !void {
    var req_path_opt: ?[]const u8 = null;
    const target = request.head.target;
    if (std.mem.indexOf(u8, target, "?")) |q_idx| {
        const query = target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "path=")) {
                req_path_opt = param[5..];
            }
        }
    }

    var target_path: []const u8 = undefined;
    if (req_path_opt) |encoded_path| {
        const decoded = try allocator.dupe(u8, encoded_path);
        target_path = std.Uri.percentDecodeInPlace(decoded);
    } else {
        target_path = "";
    }

    var resolved_path: []const u8 = undefined;
    if (target_path.len == 0) {
        if (c.getenv("HOME")) |home| {
            resolved_path = try allocator.dupe(u8, std.mem.span(home));
        } else {
            resolved_path = try allocator.dupe(u8, "/");
        }
    } else {
        if (std.fs.path.resolve(allocator, &[_][]const u8{target_path})) |res| {
            resolved_path = res;
        } else |_| {
            if (c.getenv("HOME")) |home| {
                resolved_path = try allocator.dupe(u8, std.mem.span(home));
            } else {
                resolved_path = try allocator.dupe(u8, "/");
            }
        }
    }

    var dir_list = std.ArrayList([]const u8).empty;
    defer {
        for (dir_list.items) |d| allocator.free(d);
        dir_list.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(io, resolved_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Failed to open directory '{s}': {}\n", .{ resolved_path, err });
        try serveBrowseJson(request, allocator, resolved_path, &[_][]const u8{});
        return;
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (entry.name.len > 0 and entry.name[0] == '.') continue;
            try dir_list.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    const sortFn = struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan;
    std.mem.sort([]const u8, dir_list.items, {}, sortFn);

    try serveBrowseJson(request, allocator, resolved_path, dir_list.items);
}

pub fn serveBrowseJson(request: *std.http.Server.Request, allocator: std.mem.Allocator, current: []const u8, dirs: []const []const u8) !void {
    const parent = std.fs.path.dirname(current) orelse "";

    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"current\":\"");
    try escapeJsonString(&json, allocator, current);
    try json.appendSlice(allocator, "\",\"parent\":");
    if (parent.len > 0) {
        try json.appendSlice(allocator, "\"");
        try escapeJsonString(&json, allocator, parent);
        try json.appendSlice(allocator, "\"");
    } else {
        try json.appendSlice(allocator, "null");
    }
    try json.appendSlice(allocator, ",\"directories\":[");
    for (dirs, 0..) |d, i| {
        if (i > 0) try json.appendSlice(allocator, ",");
        try json.appendSlice(allocator, "\"");
        try escapeJsonString(&json, allocator, d);
        try json.appendSlice(allocator, "\"");
    }
    try json.appendSlice(allocator, "]}");

    request.respond(json.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    }) catch return;
}

pub fn escapeJsonString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
}
