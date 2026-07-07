const std = @import("std");
const Config = @import("config.zig").Config;
const manifest = @import("manifest.zig");

pub fn runWatcher(allocator: std.mem.Allocator, io: std.Io, config: *const Config) void {
    std.debug.print("[Watcher] Background indexer started. Watching {s}\n", .{config.working_folder});

    const sleep_duration_ns = 5 * 60 * 1000 * 1000 * 1000; // 5 minutes

    while (true) {
        {
            var loop_arena = std.heap.ArenaAllocator.init(allocator);
            defer loop_arena.deinit();
            const loop_allocator = loop_arena.allocator();

            var dir = std.Io.Dir.cwd().openDir(io, config.working_folder, .{ .iterate = true }) catch {
                std.debug.print("[Watcher] Failed to open working folder.\n", .{});
                continue;
            };
            defer dir.close(io);

            var walker = dir.walk(loop_allocator) catch {
                std.debug.print("[Watcher] Failed to walk working folder.\n", .{});
                continue;
            };
            defer walker.deinit();

            while (walker.next(io) catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".mkv")) {
                    const full_path = std.fs.path.join(loop_allocator, &.{ config.working_folder, entry.path }) catch continue;
                    defer loop_allocator.free(full_path);

                    const cache_dir = std.fs.path.join(loop_allocator, &.{ config.working_folder, ".sratim", "manifests" }) catch continue;
                    defer loop_allocator.free(cache_dir);
                    std.Io.Dir.cwd().createDirPath(io, cache_dir) catch {};

                    const hash = std.hash.CityHash64.hash(full_path);
                    const cache_file = std.fmt.allocPrint(loop_allocator, "{s}/{d}.mpd", .{ cache_dir, hash }) catch continue;
                    defer loop_allocator.free(cache_file);

                    const splits_file = std.fmt.allocPrint(loop_allocator, "{s}/{d}.splits", .{ cache_dir, hash }) catch continue;
                    defer loop_allocator.free(splits_file);

                    // Check if cache file exists
                    if (std.Io.Dir.cwd().openFile(io, cache_file, .{})) |file| {
                        file.close(io);
                        // Cache exists, skip
                        continue;
                    } else |_| {
                        // Cache does not exist, generate it
                        std.debug.print("[Watcher] Indexing new file: {s}...\n", .{entry.path});

                        // We need to pass the raw relative path string properly. The front end might URL-encode it,
                        // but internally we just want to write `entry.path`. However, the manifest generator
                        // expects `url_file_param` to match what the player requests.
                        // For the background thread, we can just URL encode the path string.
                        var url_param_list: std.ArrayList(u8) = .empty;
                        defer url_param_list.deinit(loop_allocator);
                        for (entry.path) |c| {
                            if (c == ' ') {
                                url_param_list.appendSlice(loop_allocator, "%20") catch {};
                            } else if (c == '&') {
                                url_param_list.appendSlice(loop_allocator, "%26") catch {};
                            } else {
                                url_param_list.append(loop_allocator, c) catch {};
                            }
                        }
                        const url_file_param = url_param_list.items;

                        const result = manifest.generateMpd(loop_allocator, full_path, url_file_param) catch |err| {
                            std.debug.print("[Watcher] Failed to generate MPD for {s}: {}\n", .{ entry.path, err });
                            continue;
                        };
                        defer loop_allocator.free(result.xml);

                        // Save MPD cache
                        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache_file, .data = result.xml }) catch |err| {
                            std.debug.print("[Watcher] Failed to write MPD cache: {}\n", .{err});
                        };

                        // Save splits file
                        if (result.splits.len > 0) {
                            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = splits_file, .data = std.mem.sliceAsBytes(result.splits) }) catch |err| {
                                std.debug.print("[Watcher] Failed to write splits file: {}\n", .{err});
                            };
                        }
                        loop_allocator.free(result.splits);
                        
                        std.debug.print("[Watcher] Successfully indexed {s}.\n", .{entry.path});
                    }
                }
            }
        }
        
        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(sleep_duration_ns), .awake) catch {};
    }
}
