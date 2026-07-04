const std = @import("std");
const Config = @import("config.zig").Config;
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var config = Config.load(arena, io, "config.json") catch |err| {
        std.debug.print("Failed to load config.json: {}\n", .{err});
        std.debug.print("Make sure config.json exists in the current directory with `working_folder` and `port` fields.\n", .{});
        return;
    };
    defer config.deinit(arena);

    try server.runServer(arena, io, &config);
}
