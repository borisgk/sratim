const std = @import("std");
const server = @import("web/server.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db/db.zig");
const users_mod = @import("db/users.zig");
const logging_mod = @import("db/logging.zig");
const c = @import("core/c.zig").c;

/// The application entry point.
/// Initializes the asynchronous I/O backend and starts accepting incoming HTTP connections.
pub fn main() !void {
    // Suppress FFmpeg informational logs (like Qavg) to keep the terminal clean
    c.av_log_set_level(c.AV_LOG_WARNING);

    // Initialize the thread-based asynchronous I/O backend (uses epoll/kqueue under the hood)
    var t = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = t.io();
    
    var config = try config_mod.Config.load(std.heap.c_allocator, io, "config.json");
    defer config.deinit(std.heap.c_allocator);

    // Open SQLite database and initialize schema
    var database = try db_mod.Database.open("sratim.db");
    defer database.close();

    var logs_database = try db_mod.Database.open("logs.db");
    defer logs_database.close();

    try db_mod.initSchema(&database);
    try logging_mod.initLogsSchema(&logs_database);
    
    try users_mod.ensureAdminExists(&database, io);
    
    // Parse the loopback IP and start listening on port from config
    const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", config.port);
    var srv = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    
    std.debug.print("Listening on http://0.0.0.0:{d}\n", .{config.port});
    
    // Main server loop: accept connections forever
    while (true) {
        // Blocks until a new client connects
        const stream = srv.accept(io) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };
        
        // Spawn a brand new OS thread to handle the client
        const thread = try std.Thread.spawn(.{}, server.handleConnection, .{ stream, io, &config, &database, &logs_database });
        
        // Detach the thread so it runs independently, allowing the main loop to instantly continue
        thread.detach();
    }
}
