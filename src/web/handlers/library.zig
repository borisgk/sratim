const std = @import("std");
const db_mod = @import("../../db/db.zig");
const library_mod = @import("../../db/library.zig");

/// Handles POST /libraries/add — validates library config and inserts to DB.
pub fn handleLibraryAdd(request: *std.http.Server.Request, allocator: std.mem.Allocator, database: *db_mod.Database, body_buf: *[8192]u8) !void {
    var reader = request.readerExpectNone(body_buf);
    var body_data = std.ArrayList(u8).empty;
    defer body_data.deinit(allocator);

    var chunk_buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.readSliceShort(&chunk_buf) catch break;
        if (n == 0) break;
        try body_data.appendSlice(allocator, chunk_buf[0..n]);
    }

    var name: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var type_str: ?[]const u8 = null;

    var pairs = std.mem.splitScalar(u8, body_data.items, '&');
    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "name=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            std.mem.replaceScalar(u8, decoded, '+', ' ');
            name = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "path=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            std.mem.replaceScalar(u8, decoded, '+', ' ');
            path = std.Uri.percentDecodeInPlace(decoded);
        } else if (std.mem.startsWith(u8, pair, "type=")) {
            const raw = pair[5..];
            const decoded = allocator.dupe(u8, raw) catch continue;
            std.mem.replaceScalar(u8, decoded, '+', ' ');
            type_str = std.Uri.percentDecodeInPlace(decoded);
            if (type_str) |t| {
                type_str = std.mem.trim(u8, t, " \r\n");
            }
        }
    }

    std.debug.print("RAW BODY: {s}\n", .{body_data.items});
    std.debug.print("PARSED: name={?s}, path={?s}, type={?s}\n", .{name, path, type_str});

    if (name != null and path != null and type_str != null) {
        const lib_type = library_mod.LibraryType.fromString(type_str.?) orelse .Other;
        library_mod.addLibrary(database, name.?, path.?, lib_type) catch |err| {
            std.debug.print("Failed to add library: {}\n", .{err});
            request.respond("Error adding library folder.", .{ .status = .internal_server_error }) catch return;
            return;
        };

        request.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "location", .value = "/" },
            },
        }) catch return;
    } else {
        request.respond("Missing name, path or type", .{ .status = .bad_request }) catch return;
    }
}
