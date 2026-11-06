const std = @import("std");
const server = @import("web/server.zig");
const config_mod = @import("config.zig");
const db_mod = @import("db/db.zig");
const users_mod = @import("db/users.zig");
const logging_mod = @import("db/logging.zig");
const library_mod = @import("db/library.zig");
const scanner_mod = @import("db/scanner.zig");
const fetcher = @import("media/fetcher.zig");

pub const track_parser = @import("media/native/mkv/track_parser.zig");
pub const block_reader = @import("media/native/mkv/block_reader.zig");
pub const transcoder = @import("media/stream_audio_transcoder.zig");
pub const mkv_streamer = @import("media/native/mkv/mkv_streamer.zig");

/// The application entry point.
/// Initializes the asynchronous I/O backend and starts accepting incoming HTTP connections.
pub var app_dir: std.Io.Dir = undefined;

pub fn main() !void {
    const gpa = std.heap.smp_allocator;

    // Initialize the thread-based asynchronous I/O backend (uses epoll/kqueue under the hood)
    var t = std.Io.Threaded.init(gpa, .{});
    const io = t.io();

    var config_path: [:0]const u8 = "config.json";
    var data_dir: [:0]const u8 = "";
    var is_dev_mode = false;

    if (std.Io.Dir.cwd().access(io, "config.json", .{})) |_| {
        std.debug.print("Found local config.json, running in development mode.\n", .{});
        app_dir = std.Io.Dir.cwd();
        is_dev_mode = true;
    } else |_| {
        // Hierarchical path resolution:
        // 1. macOS Homebrew (Apple Silicon: /opt/homebrew)
        // 2. macOS Homebrew (Intel: /usr/local)
        // 3. Linux / system fallback (/etc/sratim and /var/lib/sratim)
        if (std.Io.Dir.cwd().access(io, "/opt/homebrew/etc/sratim/config.json", .{})) |_| {
            config_path = "/opt/homebrew/etc/sratim/config.json";
            data_dir = "/opt/homebrew/var/lib/sratim";
        } else |_| if (std.Io.Dir.cwd().access(io, "/usr/local/etc/sratim/config.json", .{})) |_| {
            config_path = "/usr/local/etc/sratim/config.json";
            data_dir = "/usr/local/var/lib/sratim";
        } else |_| {
            config_path = "/etc/sratim/config.json";
            data_dir = "/var/lib/sratim";
        }

        std.debug.print("Using config from: {s}\n", .{config_path});
        std.debug.print("Using data directory: {s}\n", .{data_dir});

        // Ensure data directory exists before opening
        std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};

        app_dir = std.Io.Dir.openDirAbsolute(io, data_dir, .{}) catch |err| {
            std.debug.print("Failed to open production data directory {s}: {}\n", .{ data_dir, err });
            return err;
        };
    }

    var config = try config_mod.Config.load(gpa, io, config_path);
    defer config.deinit(gpa);

    // Pure-Zig Storage paths
    const sratim_json_path = if (is_dev_mode) "sratim.json" else try std.fs.path.join(gpa, &.{ data_dir, "sratim.json" });
    const sratim_wal_path = if (is_dev_mode) "sratim.wal" else try std.fs.path.join(gpa, &.{ data_dir, "sratim.wal" });
    const persons_dir = if (is_dev_mode) ".sratim/persons" else try std.fs.path.join(gpa, &.{ data_dir, "persons" });
    std.Io.Dir.cwd().createDirPath(io, persons_dir) catch |err| {
        std.debug.print("Failed to ensure persons directory {s}: {}\n", .{ persons_dir, err });
    };
    std.debug.print("Person details directory: {s}\n", .{persons_dir});
    const logs_json_path = if (is_dev_mode) "logs.json" else try std.fs.path.join(gpa, &.{ data_dir, "logs.json" });
    const logs_wal_path = if (is_dev_mode) "logs.wal" else try std.fs.path.join(gpa, &.{ data_dir, "logs.wal" });

    var sratim_storage = db_mod.engine.SratimStorage.init(gpa, io, sratim_json_path, sratim_wal_path, persons_dir);
    defer sratim_storage.deinit();

    var logs_storage = db_mod.logs_engine.LogsStorage.init(gpa, io, logs_json_path, logs_wal_path);
    defer logs_storage.deinit();

    defer if (!is_dev_mode) {
        gpa.free(sratim_json_path);
        gpa.free(sratim_wal_path);
        gpa.free(persons_dir);
        gpa.free(logs_json_path);
        gpa.free(logs_wal_path);
    };

    // Load snapshots from disk (JSON snapshot + replay WAL if exists)
    if (sratim_storage.load()) |loaded| {
        if (loaded) {
            std.debug.print("Loaded catalog database snapshot from {s}\n", .{sratim_json_path});
        }
    } else |err| {
        std.debug.print("WARNING: Failed to load catalog database from {s}: {}\n", .{ sratim_json_path, err });
    }

    if (logs_storage.load()) |loaded| {
        if (loaded) {
            std.debug.print("Loaded logs & progress database snapshot from {s} (WAL: {s})\n", .{ logs_json_path, logs_wal_path });
        }
    } else |err| {
        std.debug.print("WARNING: Failed to load logs database from {s}: {}\n", .{ logs_json_path, err });
    }

    // Start background checkpoint thread for periodic snapshot compaction (every 60s)
    const CheckpointCtx = struct {
        logs_storage: *db_mod.logs_engine.LogsStorage,
        io: std.Io,
    };
    const checkpoint_worker = struct {
        fn run(ctx: CheckpointCtx) void {
            while (true) {
                ctx.io.sleep(std.Io.Duration.fromSeconds(60), .awake) catch break;
                ctx.logs_storage.snapshot() catch |err| {
                    std.debug.print("Checkpoint: failed to snapshot logs storage: {}\n", .{err});
                };
            }
        }
    }.run;

    const checkpoint_thread = try std.Thread.spawn(.{}, checkpoint_worker, .{CheckpointCtx{
        .logs_storage = &logs_storage,
        .io = io,
    }});
    checkpoint_thread.detach();

    var database = db_mod.Database.init(&sratim_storage, &logs_storage);

    try users_mod.ensureAdminExists(&database, io);

    std.debug.print("Scanning libraries for files...\n", .{});
    scanner_mod.scanLibraryFiles(&database, gpa, io) catch |err| {
        std.debug.print("Error scanning libraries: {}\n", .{err});
    };
    std.debug.print("Library scan complete.\n", .{});

    fetcher.startFetcherThread(gpa, io, &database, config.getTmdbToken(), config.tmdb_proxy) catch |err| {
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
        const thread = try std.Thread.spawn(.{}, server.handleConnection, .{ stream, io, &config, &database });

        // Detach the thread so it runs independently, allowing the main loop to instantly continue
        thread.detach();
    }
}

const build_options = @import("build_options");

test {
    _ = @import("media/subtitles.zig");
    _ = @import("media/subtitles_test.zig");
    _ = @import("media/metadata.zig");
    _ = @import("media/metadata_test.zig");
    _ = @import("media/tmdb.zig");
    _ = @import("media/tmdb_test.zig");
    _ = @import("media/native/metadata.zig");
    _ = @import("media/native/metadata_test.zig");
    _ = @import("media/native/detector.zig");
    _ = @import("media/native/detector_test.zig");
    _ = @import("media/native/isobmff.zig");
    _ = @import("media/native/isobmff_test.zig");
    _ = @import("media/native/fmp4_muxer.zig");
    _ = @import("media/native/fmp4_muxer_test.zig");
    _ = @import("media/native/mp4_streamer.zig");
    _ = @import("media/native/mp4_streamer_test.zig");
    _ = @import("media/native/subtitles.zig");
    _ = @import("media/native/subtitles_test.zig");
    _ = @import("media/native/subtitles/vtt.zig");
    _ = @import("media/native/subtitles/vtt_test.zig");
    _ = @import("media/native/languages.zig");
    _ = @import("media/native/languages_test.zig");
    _ = @import("media/native/codecs.zig");
    _ = @import("media/native/codecs_test.zig");
    _ = @import("media/native/ebml.zig");
    _ = @import("media/native/ebml_test.zig");
    _ = @import("media/native/cues.zig");
    _ = @import("media/native/cues_test.zig");
    _ = @import("media/native/mkv/track_parser.zig");
    _ = @import("media/native/mkv/track_parser_test.zig");
    _ = @import("media/native/mkv/gop_builder.zig");
    _ = @import("media/native/mkv/gop_builder_test.zig");
    _ = @import("media/native/mkv/mkv_streamer.zig");
    _ = @import("media/stream_audio_transcoder.zig");
    _ = @import("media/stream_audio_transcoder_test.zig");
    _ = @import("media/native/audio/mdct.zig");
    _ = @import("media/native/audio/mdct_test.zig");
    _ = @import("media/native/audio/imdct.zig");
    _ = @import("media/native/audio/imdct_test.zig");
    _ = @import("media/native/audio/dsp.zig");
    _ = @import("media/native/audio/dsp_test.zig");
    _ = @import("media/native/audio/dts_dec.zig");
    _ = @import("media/native/audio/dts_dec_test.zig");
    _ = @import("media/native/audio/ac3_dec.zig");
    _ = @import("media/native/audio/ac3_dec_test.zig");
    _ = @import("media/native/audio/eac3_dec.zig");
    _ = @import("media/native/audio/eac3_dec_test.zig");
    _ = @import("media/native/audio/aac_dec.zig");
    _ = @import("media/native/audio/aac_dec_test.zig");
    _ = @import("media/native/audio/aac_enc.zig");
    _ = @import("media/native/audio/aac_enc_test.zig");
    _ = @import("media/native/audio/mp3_dec.zig");
    _ = @import("media/native/audio/mp3_dec_test.zig");
    _ = @import("media/native/audio/mp3/decoder_test.zig");
    _ = @import("media/native/audio/fifo.zig");
    _ = @import("media/native/audio/fifo_test.zig");
    _ = @import("media/native/audio/aac/huffman_test.zig");
    _ = @import("media/native/audio/dts/header_test.zig");
    _ = @import("media/native/audio/dts/subband_test.zig");
    _ = @import("media/native/audio/dts/synthesis_test.zig");
    _ = @import("storage/storage_test.zig");
    _ = @import("utils/parser.zig");
    _ = @import("db/scanner.zig");
    _ = @import("db/scanner_test.zig");
    _ = @import("db/analytics.zig");
    _ = @import("db/analytics_test.zig");
    _ = @import("db/admin.zig");
    _ = @import("db/admin_test.zig");
    _ = @import("storage/sort.zig");
    _ = @import("web/utils.zig");
    _ = @import("web/utils_test.zig");
    _ = @import("web/handlers/analytics_admin.zig");
    _ = @import("web/handlers/analytics_admin_test.zig");
    _ = @import("web/handlers/show.zig");
    _ = @import("web/handlers/show_test.zig");
    _ = @import("web/catalog/cards_test.zig");
    if (build_options.test_audio) {
        _ = @import("media/native/audio/test_ac3_mkv.zig");
        _ = @import("media/native/audio/test_eac3_mkv.zig");
        _ = @import("media/native/audio/test_aac_mkv.zig");
        _ = @import("media/native/audio/test_mp3_mkv.zig");
    }
}
