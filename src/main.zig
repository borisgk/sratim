const std = @import("std");
const server = @import("server.zig");
const config_mod = @import("config.zig");
const c = @import("c.zig").c;

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
    
    // Parse the loopback IP and start listening on port from config
    const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", config.port);
    var srv = try std.Io.net.IpAddress.listen(&addr, io, .{ .reuse_address = true });
    
    std.debug.print("Listening on http://127.0.0.1:8000\n", .{});
    
    // Main server loop: accept connections forever
    while (true) {
        // Blocks until a new client connects
        const stream = srv.accept(io) catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            continue;
        };
        
        // Spawn a brand new OS thread to handle the client
        const thread = try std.Thread.spawn(.{}, server.handleConnection, .{ stream, io, config.working_folder });
        
        // Detach the thread so it runs independently, allowing the main loop to instantly continue
        thread.detach();
    }
}
