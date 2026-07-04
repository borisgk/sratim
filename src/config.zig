const std = @import("std");

pub const Config = struct {
    working_folder: []const u8,
    port: u16,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const file_content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(file_content);

        const parsed = try std.json.parseFromSlice(Config, allocator, file_content, .{
            .allocate = .alloc_always,
        });
        
        return parsed.value;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.working_folder);
    }
};
