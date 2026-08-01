const std = @import("std");

pub const Config = struct {

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

        const token = if (parsed.value.tmdb_access_token) |t| try allocator.dupe(u8, t) else null;
        const proxy = if (parsed.value.tmdb_proxy) |p| try allocator.dupe(u8, p) else null;

        return .{

            .port = parsed.value.port,
            .tmdb_access_token = token,
            .tmdb_proxy = proxy,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {

        if (self.tmdb_access_token) |t| allocator.free(t);
        if (self.tmdb_proxy) |p| allocator.free(p);
    }
};
