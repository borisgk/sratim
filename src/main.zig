const std = @import("std");
const server = @import("web/server.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db/db.zig");
const users_mod = @import("db/users.zig");
const logging_mod = @import("db/logging.zig");
const library_mod = @import("db/library.zig");
const scanner_mod = @import("db/scanner.zig");
const fetcher = @import("media/fetcher.zig");
const c = @import("core/c.zig").c;

/// The application entry point.
/// Initializes the asynchronous I/O backend and starts accepting incoming HTTP connections.
pub var app_dir: std.Io.Dir = undefined;

pub fn main() !void {
    // Suppress FFmpeg informational logs and warnings to keep the terminal clean
    c.av_log_set_level(c.AV_LOG_ERROR);

    // Initialize the thread-based asynchronous I/O backend (uses epoll/kqueue under the hood)
    var t = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = t.io();
    
    var config_path: [:0]const u8 = "config.json";
    var db_path: [:0]const u8 = "sratim.db";
    var logs_db_path: [:0]const u8 = "logs.db";

    if (std.Io.Dir.cwd().access(io, "config.json", .{})) |_| {
        std.debug.print("Found local config.json, running in development mode.\n", .{});
        app_dir = std.Io.Dir.cwd();
    } else |_| {
        std.debug.print("Local config.json not found, falling back to system paths.\n", .{});
        config_path = "/etc/sratim/config.json";
        db_path = "/var/lib/sratim/sratim.db";
        logs_db_path = "/var/lib/sratim/logs.db";
        app_dir = std.Io.Dir.openDirAbsolute(io, "/var/lib/sratim", .{}) catch |err| {
            std.debug.print("Failed to open production data directory /var/lib/sratim: {}\n", .{err});
            return err;
        };
    }

    var config = try config_mod.Config.load(std.heap.c_allocator, io, config_path);
    defer config.deinit(std.heap.c_allocator);

    // Open SQLite database and initialize schema
    var database = try db_mod.Database.open(db_path);
    defer database.close();

    var logs_database = try db_mod.Database.open(logs_db_path);
    defer logs_database.close();

    try db_mod.initSchema(&database);
    try logging_mod.initLogsSchema(&logs_database);
    
    try users_mod.ensureAdminExists(&database, io);
    
    std.debug.print("Scanning libraries for files...\n", .{});
    scanner_mod.scanLibraryFiles(&database, std.heap.c_allocator, io) catch |err| {
        std.debug.print("Error scanning libraries: {}\n", .{err});
    };
    std.debug.print("Library scan complete.\n", .{});
    
    fetcher.startFetcherThread(std.heap.c_allocator, io, &database, config.tmdb_access_token, config.tmdb_proxy) catch |err| {
        std.debug.print("Failed to start TMDB fetcher: {}\n", .{err});
    };
    
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

test {
    _ = @import("media/subtitles.zig");
}
