const std = @import("std");

/// Saves bytes atomically to target path using a temporary file and rename.
pub fn saveAtomic(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var writer = file.writer(io, &file_buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();

    // Atomic replace
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Reads snapshot file contents if present.
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) !?[]u8 {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_bytes)) catch |err| {
        if (err == error.FileNotFound) return null;
        return err;
    };
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(content);
        return null;
    }
    return content;
}
