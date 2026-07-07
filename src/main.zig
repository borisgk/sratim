const std = @import("std");
const Config = @import("config.zig").Config;
const server = @import("server.zig");
const watcher = @import("watcher.zig");
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    
    const io = init.io;

    var config = Config.load(allocator, io, "config.json") catch |err| {
        std.debug.print("Failed to load config.json: {}\n", .{err});
        std.debug.print("Make sure config.json exists in the current directory with `working_folder` and `port` fields.\n", .{});
        return;
    };
    defer config.deinit(allocator);

    @import("packager.zig").init();

    _ = try std.Thread.spawn(.{}, watcher.runWatcher, .{ allocator, io, &config });

    try server.runServer(allocator, io, &config);
}
