const std = @import("std");
const server = @import("server.zig");

/// The application entry point.
/// Initializes the asynchronous I/O backend and starts accepting incoming HTTP connections.
pub fn main() !void {
    // Initialize the thread-based asynchronous I/O backend (uses epoll/kqueue under the hood)
    var t = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = t.io();
    
    // Parse the loopback IP and start listening on port 8000
    const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 8000);
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
        const thread = try std.Thread.spawn(.{}, server.handleConnection, .{ stream, io });
        
        // Detach the thread so it runs independently, allowing the main loop to instantly continue
        thread.detach();
    }
}
