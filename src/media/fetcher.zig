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

fn fetcherLoop(allocator: std.mem.Allocator, io: std.Io, database: *db_mod.Database, token: []const u8, proxy_url: ?[]const u8) void {
    std.debug.print("TMDB background fetcher started.\n", .{});

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

                // Fetch cast & directors
                if (tmdb.fetchMovieCredits(allocator, io, first.id, token, proxy_url)) |credits_parsed| {
                    defer credits_parsed.deinit();
                    const credits = credits_parsed.value;
                    const cast_limit = @min(credits.cast.len, 20);
                    for (credits.cast[0..cast_limit]) |c| {
                        if (c.profile_path) |p| {
                            tmdb.downloadProfileImage(allocator, io, p, proxy_url) catch {};
                        }
                    }
                    for (credits.crew) |cr| {
                        if (std.mem.eql(u8, cr.job, "Director")) {
                            if (cr.profile_path) |p| {
                                tmdb.downloadProfileImage(allocator, io, p, proxy_url) catch {};
                            }
                        }
                    }
                    metadata_mod.saveMovieCredits(database, movie.id, credits.cast, credits.crew) catch |err| {
                        std.debug.print("TMDB fetcher error saving credits for {s}: {}\n", .{movie.clean_name, err});
                    };
                } else |err| {
                    std.debug.print("TMDB fetcher error fetching credits for {s}: {}\n", .{movie.clean_name, err});
                }
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

        // Backfill Credits for existing movies that have TMDB IDs but missing credits
        const missing_credits = metadata_mod.getMoviesMissingCredits(database, allocator) catch |err| {
            std.debug.print("TMDB fetcher error querying movies missing credits: {}\n", .{err});
            io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch {};
            continue;
        };
        defer {
            for (missing_credits) |*m| {
                var mut = m.*;
                mut.deinit(allocator);
            }
            allocator.free(missing_credits);
        }

        if (missing_credits.len > 0) {
            std.debug.print("TMDB fetcher found {d} movies needing credits backfill.\n", .{missing_credits.len});
            for (missing_credits, 0..) |movie, idx| {
                const tmdb_id = movie.tmdb_id orelse {
                    metadata_mod.markMovieCreditsFetched(database, movie.id);
                    continue;
                };

                const display_title = movie.title orelse movie.clean_name;
                std.debug.print("TMDB backfilling credits [{d}/{d}]: {s} (TMDB ID {d})\n", .{
                    idx + 1, missing_credits.len, display_title, tmdb_id,
                });

                if (tmdb.fetchMovieCredits(allocator, io, tmdb_id, token, proxy_url)) |credits_parsed| {
                    defer credits_parsed.deinit();
                    const credits = credits_parsed.value;

                    // Download profile pictures for top cast
                    const cast_limit = @min(credits.cast.len, 20);
                    for (credits.cast[0..cast_limit]) |c| {
                        if (c.profile_path) |p| {
                            tmdb.downloadProfileImage(allocator, io, p, proxy_url) catch {};
                        }
                    }
                    // Download profile pictures for directors
                    for (credits.crew) |cr| {
                        if (std.mem.eql(u8, cr.job, "Director")) {
                            if (cr.profile_path) |p| {
                                tmdb.downloadProfileImage(allocator, io, p, proxy_url) catch {};
                            }
                        }
                    }

                    metadata_mod.saveMovieCredits(database, movie.id, credits.cast, credits.crew) catch |err| {
                        std.debug.print("TMDB fetcher error saving credits for {s}: {}\n", .{ movie.clean_name, err });
                    };
                } else |err| {
                    std.debug.print("TMDB fetcher error fetching credits for {s}: {}\n", .{ movie.clean_name, err });
                    metadata_mod.markMovieCreditsFetched(database, movie.id);
                }

                // 1-second interval between TMDB requests
                io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
            }
        }

        // Backfill / Refresh person details & filmography (30-day base TTL with jitter)
        const refresh_people = metadata_mod.getPeopleNeedingRefresh(database, allocator, 30 * 24 * 3600) catch |err| {
            std.debug.print("TMDB fetcher error querying person refresh candidates: {}\n", .{err});
            io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch {};
            continue;
        };
        defer {
            for (refresh_people) |*p| {
                var mut_p = p.*;
                mut_p.deinit(allocator);
            }
            allocator.free(refresh_people);
        }

        if (refresh_people.len > 0) {
            std.debug.print("TMDB fetcher found {d} persons needing details backfill or refresh.\n", .{refresh_people.len});
            var stale_count: usize = 0;
            const max_stale_per_pass: usize = 10;

            for (refresh_people, 0..) |person, idx| {
                const is_stale = person.details_updated_at != 0;
                if (is_stale) {
                    if (stale_count >= max_stale_per_pass) continue;
                    stale_count += 1;
                }

                std.debug.print("TMDB {s} person details [{d}/{d}]: {s} (ID {d})\n", .{
                    if (is_stale) "refreshing" else "backfilling",
                    idx + 1, refresh_people.len, person.name, person.id,
                });

                if (tmdb.fetchPersonDetails(allocator, io, person.id, token, proxy_url)) |details_parsed| {
                    defer details_parsed.deinit();
                    const d = details_parsed.value;

                    var filmography_json: ?[]const u8 = null;
                    defer if (filmography_json) |fj| allocator.free(fj);

                    if (d.movie_credits) |credits| {
                        filmography_json = tmdb.buildFilmographyJson(allocator, credits) catch null;
                    }

                    metadata_mod.savePersonDetails(
                        database,
                        person.id,
                        d.biography,
                        d.birthday,
                        d.deathday,
                        d.place_of_birth,
                        d.imdb_id,
                        filmography_json,
                    ) catch |err| {
                        std.debug.print("TMDB fetcher error saving person details for {s}: {}\n", .{ person.name, err });
                    };
                } else |err| {
                    std.debug.print("TMDB fetcher error fetching details for {s}: {}\n", .{ person.name, err });
                    metadata_mod.markPersonDetailsFetched(database, person.id);
                }

                // 1-second interval between TMDB requests
                io.sleep(std.Io.Duration.fromSeconds(1), .awake) catch {};
            }
        }

        // Sleep 30 seconds before polling again
        io.sleep(std.Io.Duration.fromSeconds(30), .awake) catch {};
    }
}
