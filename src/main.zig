const std = @import("std");
const server = @import("web/server.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db/db.zig");
const users_mod = @import("db/users.zig");
const logging_mod = @import("db/logging.zig");
const library_mod = @import("db/library.zig");
const scanner_mod = @import("db/scanner.zig");
const fetcher = @import("media/fetcher.zig");

/// The application entry point.
/// Initializes the asynchronous I/O backend and starts accepting incoming HTTP connections.
pub var app_dir: std.Io.Dir = undefined;

pub fn main() !void {
    // Initialize the thread-based asynchronous I/O backend (uses epoll/kqueue under the hood)
    var t = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = t.io();
    
    var config_path: [:0]const u8 = "config.json";

    if (std.Io.Dir.cwd().access(io, "config.json", .{})) |_| {
        std.debug.print("Found local config.json, running in development mode.\n", .{});
        app_dir = std.Io.Dir.cwd();
    } else |_| {
        std.debug.print("Local config.json not found, falling back to system paths.\n", .{});
        config_path = "/etc/sratim/config.json";
        app_dir = std.Io.Dir.openDirAbsolute(io, "/var/lib/sratim", .{}) catch |err| {
            std.debug.print("Failed to open production data directory /var/lib/sratim: {}\n", .{err});
            return err;
        };
    }

    var config = try config_mod.Config.load(std.heap.c_allocator, io, config_path);
    defer config.deinit(std.heap.c_allocator);

    // Pure-Zig Storage paths
    const sratim_json_path = if (std.mem.eql(u8, config_path, "config.json")) "sratim.json" else "/var/lib/sratim/sratim.json";
    const sratim_wal_path = if (std.mem.eql(u8, config_path, "config.json")) "sratim.wal" else "/var/lib/sratim/sratim.wal";
    const logs_json_path = if (std.mem.eql(u8, config_path, "config.json")) "logs.json" else "/var/lib/sratim/logs.json";
    const logs_wal_path = if (std.mem.eql(u8, config_path, "config.json")) "logs.wal" else "/var/lib/sratim/logs.wal";

    var sratim_storage = db_mod.engine.SratimStorage.init(std.heap.c_allocator, io, sratim_json_path, sratim_wal_path);
    defer sratim_storage.deinit();

    var logs_storage = db_mod.logs_engine.LogsStorage.init(std.heap.c_allocator, io, logs_json_path, logs_wal_path);
    defer logs_storage.deinit();

    // Load snapshots from disk (JSON snapshot + replay WAL if exists)
    _ = sratim_storage.load() catch false;
    _ = logs_storage.load() catch false;

    var database = db_mod.Database.forCatalog(&sratim_storage);
    var logs_database = db_mod.Database.forLogs(&logs_storage);

    try users_mod.ensureAdminExists(&database, io);
    
    std.debug.print("Scanning libraries for files...\n", .{});
    scanner_mod.scanLibraryFiles(&database, std.heap.c_allocator, io) catch |err| {
        std.debug.print("Error scanning libraries: {}\n", .{err});
    };
    std.debug.print("Library scan complete.\n", .{});
    
    fetcher.startFetcherThread(std.heap.c_allocator, io, &database, config.getTmdbToken(), config.tmdb_proxy) catch |err| {
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

const build_options = @import("build_options");

test {
    _ = @import("media/subtitles.zig");
    _ = @import("media/metadata.zig");
    _ = @import("media/native/metadata.zig");
    _ = @import("media/native/detector.zig");
    _ = @import("media/native/isobmff.zig");
    _ = @import("media/native/fmp4_muxer.zig");
    _ = @import("media/native/mp4_streamer.zig");
    _ = @import("media/native/mkv/track_parser.zig");
    _ = @import("media/native/mkv/gop_builder.zig");
    _ = @import("media/native/mkv/mkv_streamer.zig");
    _ = @import("storage/test_storage.zig");
    if (build_options.test_audio) {
        _ = @import("media/native/audio/test_ac3_mkv.zig");
        _ = @import("media/native/audio/test_eac3_mkv.zig");
        _ = @import("media/native/audio/test_aac_mkv.zig");
        _ = @import("media/native/audio/test_mp3_mkv.zig");
    }
}
