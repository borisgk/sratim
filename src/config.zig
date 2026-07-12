const std = @import("std");

pub const Config = struct {
    working_folder: []const u8,
    port: u16,
    tmdb_access_token: ?[]const u8 = null,
    tmdb_proxy: ?[]const u8 = null,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const file_content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(file_content);

        const parsed = try std.json.parseFromSlice(Config, allocator, file_content, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // Dupe the string so it outlives the parser arena
        const folder = try allocator.dupe(u8, parsed.value.working_folder);
        const token = if (parsed.value.tmdb_access_token) |t| try allocator.dupe(u8, t) else null;
        const proxy = if (parsed.value.tmdb_proxy) |p| try allocator.dupe(u8, p) else null;

        return .{
            .working_folder = folder,
            .port = parsed.value.port,
            .tmdb_access_token = token,
            .tmdb_proxy = proxy,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.working_folder);
        if (self.tmdb_access_token) |t| allocator.free(t);
        if (self.tmdb_proxy) |p| allocator.free(p);
    }
};
