const std = @import("std");
const tmdb = @import("tmdb.zig");
const metadata_mod = @import("../db/metadata.zig");
const db_mod = @import("../db/db.zig");

pub fn startFetcherThread(allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, token: ?[]const u8, proxy_url: ?[]const u8) !void {
    if (token == null or token.?.len == 0) {
        std.debug.print("TMDB background fetcher disabled (no token configured)\n", .{});
        return;
    }

    // Spawn the thread
    const thread = try std.Thread.spawn(.{}, fetcherLoop, .{ allocator, io, database, token.?, proxy_url });
    thread.detach();
}

fn fetcherLoop(allocator: std.mem.Allocator, io: std.Io, database_shared: *db_mod.Database, token: []const u8, proxy_url: ?[]const u8) void {
    _ = database_shared;
    std.debug.print("TMDB background fetcher started.\n", .{});

    var database_val = db_mod.Database.open("sratim.db") catch |err| {
        std.debug.print("Failed to open database in fetcher thread: {}\n", .{err});
        return;
    };
    defer database_val.close();
    const database = &database_val;

    while (true) {
        // Query missing metadata
        const missing = metadata_mod.getMoviesMissingMetadata(database, allocator) catch |err| {
            std.debug.print("TMDB fetcher error querying missing metadata: {}\n", .{err});
            io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch {};
            continue;
        };

        if (missing.len > 0) {
            std.debug.print("TMDB fetcher found {d} movies missing metadata.\n", .{missing.len});
        }

        for (missing) |movie| {
            // Process each movie
            std.debug.print("TMDB fetcher processing: {s}\n", .{movie.clean_name});
            
            // Parse year and clean name
            const parsed_name = tmdb.parseYearAndCleanName(allocator, movie.clean_name) catch |err| {
                std.debug.print("Error parsing name for {s}: {}\n", .{movie.clean_name, err});
                continue;
            };
            defer {
                if (parsed_name.clean.ptr != movie.clean_name.ptr) allocator.free(parsed_name.clean);
                if (parsed_name.year) |y| allocator.free(y);
            }

            const results = tmdb.searchMovie(allocator, io, parsed_name.clean, parsed_name.year, token, proxy_url) catch |err| {
                std.debug.print("TMDB fetcher error searching for {s}: {}\n", .{movie.clean_name, err});
                io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
                continue;
            };
            defer results.deinit();

            if (results.value.results.len > 0) {
                const first = results.value.results[0];
                std.debug.print("TMDB fetcher found match: {s}\n", .{first.title});
                
                tmdb.downloadImages(allocator, io, first.poster_path, first.backdrop_path, proxy_url) catch |err| {
                    std.debug.print("TMDB fetcher error downloading images for {s}: {}\n", .{movie.clean_name, err});
                };

                metadata_mod.saveMetadataById(
                    database,
                    movie.id,
                    first.id,
                    first.title,
                    first.overview,
                    first.poster_path,
                    first.backdrop_path,
                    first.release_date
                ) catch |err| {
                    std.debug.print("TMDB fetcher error saving metadata for {s}: {}\n", .{movie.clean_name, err});
                };
            } else {
                std.debug.print("TMDB fetcher found NO MATCH for: {s}\n", .{movie.clean_name});
                metadata_mod.markMetadataNotFound(database, movie.id) catch |err| {
                    std.debug.print("TMDB fetcher error marking not found for {s}: {}\n", .{movie.clean_name, err});
                };
            }

            // Sleep 500ms between requests to avoid rate limits
            io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};
        }

        for (missing) |movie| {
            allocator.free(movie.clean_name);
        }
        allocator.free(missing);

        // Fetch TV Shows
        const missing_shows = metadata_mod.getShowsMissingMetadata(database, allocator) catch |err| {
            std.debug.print("TMDB fetcher error querying missing shows metadata: {}\n", .{err});
            io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch {};
            continue;
        };

        if (missing_shows.len > 0) {
            std.debug.print("TMDB fetcher found {d} shows missing metadata.\n", .{missing_shows.len});
        }

        for (missing_shows) |show| {
            std.debug.print("TMDB fetcher processing show: {s}\n", .{show.clean_name});
            
            const parsed_name = tmdb.parseYearAndCleanName(allocator, show.clean_name) catch |err| {
                std.debug.print("Error parsing name for show {s}: {}\n", .{show.clean_name, err});
                continue;
            };
            defer {
                if (parsed_name.clean.ptr != show.clean_name.ptr) allocator.free(parsed_name.clean);
                if (parsed_name.year) |y| allocator.free(y);
            }

            const results = tmdb.searchShow(allocator, io, parsed_name.clean, parsed_name.year, token, proxy_url) catch |err| {
                std.debug.print("TMDB fetcher error searching for show {s}: {}\n", .{show.clean_name, err});
                io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
                continue;
            };
            defer results.deinit();

            if (results.value.results.len > 0) {
                const first = results.value.results[0];
                std.debug.print("TMDB fetcher found show match: {s}\n", .{first.name});
                
                tmdb.downloadImages(allocator, io, first.poster_path, first.backdrop_path, proxy_url) catch |err| {
                    std.debug.print("TMDB fetcher error downloading images for show {s}: {}\n", .{show.clean_name, err});
                };

                metadata_mod.saveShowMetadataById(
                    database,
                    show.id,
                    first.id,
                    first.name,
                    first.overview,
                    first.poster_path,
                    first.backdrop_path,
                    first.first_air_date
                ) catch |err| {
                    std.debug.print("TMDB fetcher error saving metadata for show {s}: {}\n", .{show.clean_name, err});
                };
            } else {
                std.debug.print("TMDB fetcher found NO SHOW MATCH for: {s}\n", .{show.clean_name});
                metadata_mod.markShowMetadataNotFound(database, show.id) catch |err| {
                    std.debug.print("TMDB fetcher error marking show not found for {s}: {}\n", .{show.clean_name, err});
                };
            }

            io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};
        }

        for (missing_shows) |show| {
            allocator.free(show.clean_name);
        }
        allocator.free(missing_shows);

        // Fetch Episodes
        const missing_episodes = metadata_mod.getEpisodesMissingMetadata(database, allocator) catch |err| {
            std.debug.print("TMDB fetcher error querying missing episodes metadata: {}\n", .{err});
            io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch {};
            continue;
        };

        if (missing_episodes.len > 0) {
            std.debug.print("TMDB fetcher found {d} episodes missing metadata.\n", .{missing_episodes.len});
        }

        for (missing_episodes) |ep| {
            std.debug.print("TMDB fetcher processing episode: Show {d}, S{d}E{d}\n", .{ep.show_tmdb_id, ep.season, ep.episode});
            
            const results = tmdb.fetchEpisode(allocator, io, ep.show_tmdb_id, ep.season, ep.episode, token, proxy_url) catch |err| {
                if (err == error.NotFound) {
                    std.debug.print("TMDB fetcher found NO EPISODE MATCH for: Show {d}, S{d}E{d}\n", .{ep.show_tmdb_id, ep.season, ep.episode});
                    metadata_mod.markEpisodeMetadataNotFound(database, ep.id) catch |e| {
                        std.debug.print("TMDB fetcher error marking episode not found: {}\n", .{e});
                    };
                } else {
                    std.debug.print("TMDB fetcher error searching for episode: {}\n", .{err});
                    io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
                }
                continue;
            };
            defer results.deinit();

            const episode_data = results.value;
            std.debug.print("TMDB fetcher found episode match: {s}\n", .{episode_data.name});
            
            tmdb.downloadImages(allocator, io, null, episode_data.still_path, proxy_url) catch |err| {
                std.debug.print("TMDB fetcher error downloading images for episode: {}\n", .{err});
            };

            metadata_mod.saveEpisodeMetadataById(
                database,
                ep.id,
                episode_data.id,
                episode_data.name,
                episode_data.overview,
                episode_data.still_path
            ) catch |err| {
                std.debug.print("TMDB fetcher error saving metadata for episode: {}\n", .{err});
            };

            io.sleep(std.Io.Duration.fromMilliseconds(500), .awake) catch {};
        }

        allocator.free(missing_episodes);

        // Sleep 30 seconds before polling again
        io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch {};
    }
}
