const std = @import("std");
const db_mod = @import("../../db/db.zig");
const schema = @import("../../storage/schema.zig");
const metadata_mod = @import("../../db/metadata.zig");
const logging_mod = @import("../../db/logging.zig");
const cards = @import("cards.zig");
const utils = @import("../utils.zig");
const tmdb = @import("../../media/tmdb.zig");
const config_mod = @import("../../config.zig");

const global_css: []const u8 = @embedFile("../style.css");
const template: []const u8 = @embedFile("../templates/person.html");

pub fn generatePersonHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
    database: *db_mod.Database,
    person_id: i64,
    username: []const u8,
    is_admin: bool,
) ![]u8 {
    const person_opt = try metadata_mod.getPersonById(database, allocator, person_id);
    if (person_opt == null) return error.PersonNotFound;
    var person = person_opt.?;
    defer person.deinit(allocator);

    // Load cold person details from disk on-demand
    var details_parsed_opt = metadata_mod.getPersonDetails(database, allocator, person_id) catch null;
    defer if (details_parsed_opt) |*dp| dp.deinit();

    // On-demand fallback fetch if details have not been fetched yet or missing from disk
    if (!person.details_fetched or person.details_updated_at == 0 or details_parsed_opt == null) {
        const token = config.getTmdbToken();
        if (token.len > 0) {
            if (tmdb.fetchPersonDetails(allocator, io, person.id, token, config.tmdb_proxy)) |parsed| {
                defer parsed.deinit();
                const details = parsed.value;

                var filmography_json: ?[]const u8 = null;
                if (details.movie_credits) |credits| {
                    filmography_json = tmdb.buildFilmographyJson(allocator, credits) catch null;
                }
                defer if (filmography_json) |fj| allocator.free(fj);

                metadata_mod.savePersonDetails(
                    database,
                    person.id,
                    details.biography,
                    details.birthday,
                    details.deathday,
                    details.place_of_birth,
                    details.imdb_id,
                    filmography_json,
                ) catch {};

                if (details.profile_path) |prof| {
                    metadata_mod.updatePersonProfilePath(database, person.id, prof) catch {};
                    tmdb.downloadProfileImage(allocator, io, prof, config.tmdb_proxy) catch {};
                } else if (person.profile_path) |prof| {
                    tmdb.downloadProfileImage(allocator, io, prof, config.tmdb_proxy) catch {};
                }

                // Reload person with updated details
                if (metadata_mod.getPersonById(database, allocator, person_id) catch null) |updated| {
                    person.deinit(allocator);
                    person = updated;
                }

                // Re-read cold details from disk
                if (details_parsed_opt) |*dp| dp.deinit();
                details_parsed_opt = metadata_mod.getPersonDetails(database, allocator, person_id) catch null;
            } else |_| {
                metadata_mod.markPersonDetailsFetched(database, person.id);
            }
        }
    }

    const details_opt: ?schema.PersonDetails = if (details_parsed_opt) |dp| dp.value else null;

    const credits = try metadata_mod.getCreditsByPerson(database, allocator, person_id);
    defer {
        for (credits) |*c| {
            var mut_c = c.*;
            mut_c.deinit(allocator);
        }
        allocator.free(credits);
    }

    const progress_opt = logging_mod.getProgressForUser(database, allocator, username) catch null;
    defer if (progress_opt) |pl| allocator.free(pl);
    const progress_list = progress_opt orelse &[_]logging_mod.ProgressInfo{};

    const cat = database.catalog orelse return error.CatalogNotConfigured;

    // Track TMDB IDs of movies in the user's library for badge display
    var library_tmdb_ids = std.AutoHashMap(i64, void).init(allocator);
    defer library_tmdb_ids.deinit();

    for (credits) |c| {
        if (cat.getMovieById(allocator, c.movie_id) catch null) |m| {
            defer {
                var mut_m = m;
                mut_m.deinit(allocator);
            }
            if (m.is_present) {
                if (m.tmdb_id) |tid| {
                    library_tmdb_ids.put(tid, {}) catch {};
                }
            }
        }
    }

    var escaped_person_name = std.ArrayList(u8).empty;
    defer escaped_person_name.deinit(allocator);
    try utils.escapeHtml(&escaped_person_name, allocator, person.name);

    const avatar_html = try renderAvatarHtml(allocator, person.profile_path, escaped_person_name.items);
    defer allocator.free(avatar_html);

    const role_str = determineRole(credits, person.known_for_department);

    const meta_html = try renderMetaHtml(allocator, details_opt, person.id);
    defer allocator.free(meta_html);

    const bio_html = try renderBioHtml(allocator, details_opt);
    defer allocator.free(bio_html);

    var directed_movie_ids = std.AutoHashMap(i64, void).init(allocator);
    defer directed_movie_ids.deinit();

    const directed_section_html = try renderDirectedSection(
        allocator,
        cat,
        credits,
        progress_list,
        person.name,
        is_admin,
        &directed_movie_ids,
    );
    defer allocator.free(directed_section_html);

    var library_movie_ids = std.AutoHashMap(i64, void).init(allocator);
    defer library_movie_ids.deinit();

    var show_count: usize = 0;
    const library_section_html = try renderLibrarySection(
        allocator,
        cat,
        credits,
        person_id,
        progress_list,
        &directed_movie_ids,
        &library_movie_ids,
        &library_tmdb_ids,
        is_admin,
        &show_count,
    );
    defer allocator.free(library_section_html);

    const filmography_section_html = try renderFilmographySection(
        allocator,
        details_opt,
        &library_tmdb_ids,
    );
    defer allocator.free(filmography_section_html);

    var total_unique_movies = std.AutoHashMap(i64, void).init(allocator);
    defer total_unique_movies.deinit();
    var d_it = directed_movie_ids.keyIterator();
    while (d_it.next()) |k| try total_unique_movies.put(k.*, {});
    var s_it = library_movie_ids.keyIterator();
    while (s_it.next()) |k| try total_unique_movies.put(k.*, {});

    const count_str = try formatItemCount(allocator, total_unique_movies.count(), show_count);
    defer allocator.free(count_str);

    var refresh_btn_html: []const u8 = "";
    if (is_admin) {
        refresh_btn_html = try std.fmt.allocPrint(allocator,
            \\<button type="button" class="btn btn-secondary person-refresh-btn" onclick="refreshPerson(this, {d})" title="Refresh metadata and filmography from TMDB">
            \\    <svg class="refresh-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" width="14" height="14">
            \\        <path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/>
            \\    </svg>
            \\    <span>Refresh</span>
            \\</button>
        , .{person.id});
    }
    defer if (is_admin and refresh_btn_html.len > 0) allocator.free(refresh_btn_html);

    var html = std.ArrayList(u8).empty;
    defer html.deinit(allocator);
    try html.appendSlice(allocator, template);

    const replacements = &[_][2][]const u8{
        .{ "__INLINE_CSS__", global_css },
        .{ "__PERSON_NAME__", escaped_person_name.items },
        .{ "__PERSON_AVATAR_HTML__", avatar_html },
        .{ "__PERSON_ROLE__", role_str },
        .{ "__MOVIES_COUNT__", count_str },
        .{ "__PERSON_META_HTML__", meta_html },
        .{ "__PERSON_BIO_HTML__", bio_html },
        .{ "__PERSON_REFRESH_BTN__", refresh_btn_html },
        .{ "__PERSON_DIRECTED_SECTION__", directed_section_html },
        .{ "__PERSON_LIBRARY_SECTION__", library_section_html },
        .{ "__PERSON_STARRING_SECTION__", library_section_html },
        .{ "__PERSON_SHOWS_SECTION__", "" },
        .{ "__PERSON_FILMOGRAPHY_SECTION__", filmography_section_html },
    };

    var current_html = html.items;
    for (replacements) |rep| {
        const placeholder = rep[0];
        const value = rep[1];
        if (std.mem.indexOf(u8, current_html, placeholder)) |_| {
            const replaced = try std.mem.replaceOwned(u8, allocator, current_html, placeholder, value);
            if (current_html.ptr != html.items.ptr) {
                allocator.free(current_html);
            }
            current_html = replaced;
        }
    }

    if (current_html.ptr == html.items.ptr) {
        return html.toOwnedSlice(allocator);
    } else {
        return current_html;
    }
}

fn determineRole(credits: []const schema.CreditRecord, known_for_department: ?[]const u8) []const u8 {
    var is_director = false;
    var is_actor = false;
    for (credits) |c| {
        if (!c.is_cast and (c.job != null and std.mem.eql(u8, c.job.?, "Director"))) {
            is_director = true;
        }
        if (c.is_cast) {
            is_actor = true;
        }
    }

    if (is_director and is_actor) {
        return "Actor & Director";
    } else if (is_director) {
        return "Director";
    } else if (known_for_department) |dept| {
        return dept;
    } else {
        return "Actor";
    }
}

fn formatItemCount(allocator: std.mem.Allocator, movie_count: usize, show_count: usize) ![]u8 {
    if (movie_count > 0 and show_count > 0) {
        return std.fmt.allocPrint(allocator, "{d} {s} and {d} {s}", .{
            movie_count,
            if (movie_count == 1) "movie" else "movies",
            show_count,
            if (show_count == 1) "show" else "shows",
        });
    } else if (show_count > 0) {
        return std.fmt.allocPrint(allocator, "{d} {s}", .{
            show_count,
            if (show_count == 1) "show" else "shows",
        });
    } else {
        return std.fmt.allocPrint(allocator, "{d} {s}", .{
            movie_count,
            if (movie_count == 1) "movie" else "movies",
        });
    }
}

fn renderAvatarHtml(allocator: std.mem.Allocator, profile_path: ?[]const u8, escaped_person_name: []const u8) ![]u8 {
    if (profile_path) |p| {
        return std.fmt.allocPrint(allocator,
            \\<img class="person-avatar-large" src="/images/profiles/w185{s}" alt="{s}" loading="lazy" onerror="if(!this.dataset.triedTmdb){{this.dataset.triedTmdb='1';this.src='https://image.tmdb.org/t/p/w185{s}';fetch('/api/images/cache?path='+encodeURIComponent('{s}')).catch(()=>{{}});}}else{{this.style.display='none';this.nextElementSibling.style.display='flex';}}">
            \\<div class="person-avatar-large-placeholder" style="display:none;">
            \\    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="48" height="48">
            \\        <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
            \\        <circle cx="12" cy="7" r="4"></circle>
            \\    </svg>
            \\</div>
        , .{ p, escaped_person_name, p, p });
    } else {
        return allocator.dupe(u8,
            \\<div class="person-avatar-large-placeholder">
            \\    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="48" height="48">
            \\        <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
            \\        <circle cx="12" cy="7" r="4"></circle>
            \\    </svg>
            \\</div>
        );
    }
}

fn renderMetaHtml(allocator: std.mem.Allocator, details_opt: ?schema.PersonDetails, person_id: i64) ![]u8 {
    var meta_items_buf = std.ArrayList(u8).empty;
    defer meta_items_buf.deinit(allocator);

    if (details_opt) |det| {
        if (det.birthday) |b| {
            if (b.len > 0) {
                try meta_items_buf.appendSlice(allocator, "        <div class=\"person-meta-item\"><span class=\"person-meta-label\">Born:</span> <span class=\"person-meta-val\">");
                try utils.escapeHtml(&meta_items_buf, allocator, b);
                try meta_items_buf.appendSlice(allocator, "</span></div>\n");
            }
        }

        if (det.deathday) |d| {
            if (d.len > 0) {
                try meta_items_buf.appendSlice(allocator, "        <div class=\"person-meta-item\"><span class=\"person-meta-label\">Died:</span> <span class=\"person-meta-val\">");
                try utils.escapeHtml(&meta_items_buf, allocator, d);
                try meta_items_buf.appendSlice(allocator, "</span></div>\n");
            }
        }

        if (det.place_of_birth) |pob| {
            if (pob.len > 0) {
                try meta_items_buf.appendSlice(allocator, "        <div class=\"person-meta-item\"><span class=\"person-meta-label\">Birthplace:</span> <span class=\"person-meta-val\">");
                try utils.escapeHtml(&meta_items_buf, allocator, pob);
                try meta_items_buf.appendSlice(allocator, "</span></div>\n");
            }
        }

        if (det.imdb_id) |imdb| {
            if (imdb.len > 0) {
                const imdb_html = try std.fmt.allocPrint(allocator,
                    \\        <div class="person-meta-item">
                    \\            <a href="https://www.imdb.com/name/{s}" target="_blank" rel="noopener noreferrer" class="person-imdb-link" title="View on IMDb">
                    \\                IMDb
                    \\                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" width="11" height="11">
                    \\                    <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
                    \\                    <polyline points="15 3 21 3 21 9"></polyline>
                    \\                    <line x1="10" y1="14" x2="21" y2="3"></line>
                    \\                </svg>
                    \\            </a>
                    \\        </div>
                    \\
                , .{imdb});
                defer allocator.free(imdb_html);
                try meta_items_buf.appendSlice(allocator, imdb_html);
            }
        }
    }

    const tmdb_html = try std.fmt.allocPrint(allocator,
        \\        <div class="person-meta-item">
        \\            <a href="https://www.themoviedb.org/person/{d}" target="_blank" rel="noopener noreferrer" class="person-tmdb-link" title="View on TMDB">
        \\                TMDB
        \\                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" width="11" height="11">
        \\                    <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
        \\                    <polyline points="15 3 21 3 21 9"></polyline>
        \\                    <line x1="10" y1="14" x2="21" y2="3"></line>
        \\                </svg>
        \\            </a>
        \\        </div>
        \\
    , .{person_id});
    defer allocator.free(tmdb_html);
    try meta_items_buf.appendSlice(allocator, tmdb_html);

    var meta_buf = std.ArrayList(u8).empty;
    defer meta_buf.deinit(allocator);
    try meta_buf.appendSlice(allocator, "    <div class=\"person-meta\">\n");
    try meta_buf.appendSlice(allocator, meta_items_buf.items);
    try meta_buf.appendSlice(allocator, "    </div>\n");

    return meta_buf.toOwnedSlice(allocator);
}

fn renderBioHtml(allocator: std.mem.Allocator, details_opt: ?schema.PersonDetails) ![]u8 {
    if (details_opt) |det| {
        if (det.biography) |bio| {
            if (bio.len > 0) {
                var bio_buf = std.ArrayList(u8).empty;
                defer bio_buf.deinit(allocator);
                try bio_buf.appendSlice(allocator,
                    \\    <div class="person-bio-wrapper">
                    \\        <div class="person-bio-heading">Biography</div>
                    \\        <div class="person-bio-text is-clamped" id="person-bio-text">
                );
                try utils.escapeHtml(&bio_buf, allocator, bio);
                try bio_buf.appendSlice(allocator,
                    \\</div>
                    \\        <div class="bio-toggle-wrapper">
                    \\            <button type="button" class="bio-toggle-btn" id="bio-toggle-btn" aria-expanded="false">
                    \\                Read More
                    \\                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" width="14" height="14">
                    \\                    <polyline points="6 9 12 15 18 9"></polyline>
                    \\                </svg>
                    \\            </button>
                    \\        </div>
                    \\    </div>
                    \\
                );
                return bio_buf.toOwnedSlice(allocator);
            }
        }
    }
    return allocator.dupe(u8, "");
}

fn renderDirectedSection(
    allocator: std.mem.Allocator,
    cat: anytype,
    credits: []const schema.CreditRecord,
    progress_list: []const logging_mod.ProgressInfo,
    person_name: []const u8,
    is_admin: bool,
    directed_movie_ids: *std.AutoHashMap(i64, void),
) ![]u8 {
    var directed_cards_buf = std.ArrayList(u8).empty;
    defer directed_cards_buf.deinit(allocator);

    for (credits) |c| {
        if (!c.is_cast and (c.job != null and std.mem.eql(u8, c.job.?, "Director"))) {
            if (!directed_movie_ids.contains(c.movie_id)) {
                if (cat.getMovieById(allocator, c.movie_id) catch null) |m| {
                    defer {
                        var mut_m = m;
                        mut_m.deinit(allocator);
                    }
                    if (m.is_present) {
                        try directed_movie_ids.put(c.movie_id, {});
                        var progress_pct: ?f64 = null;
                        for (progress_list) |item| {
                            if (item.movie_id == m.id and item.duration > 0) {
                                progress_pct = (item.position / item.duration) * 100.0;
                                break;
                            }
                        }
                        try cards.appendMovieCard(&directed_cards_buf, allocator, m.id, m.file_path, m.clean_name, m.title, m.poster_path, m.tmdb_id, progress_pct, is_admin, null);
                    }
                }
            }
        }
    }

    if (directed_movie_ids.count() == 0) {
        return allocator.dupe(u8, "");
    }

    return std.fmt.allocPrint(allocator,
        \\<div class="media-section">
        \\    <h2 class="section-title">Directed by {s}</h2>
        \\    <div class="grid movie-grid">
        \\{s}
        \\    </div>
        \\</div>
    , .{ person_name, directed_cards_buf.items });
}

fn renderLibrarySection(
    allocator: std.mem.Allocator,
    cat: anytype,
    credits: []const schema.CreditRecord,
    person_id: i64,
    progress_list: []const logging_mod.ProgressInfo,
    directed_movie_ids: *const std.AutoHashMap(i64, void),
    library_movie_ids: *std.AutoHashMap(i64, void),
    library_tmdb_ids: *std.AutoHashMap(i64, void),
    is_admin: bool,
    show_count: *usize,
) ![]u8 {
    var library_cards_buf = std.ArrayList(u8).empty;
    defer library_cards_buf.deinit(allocator);

    // 1. Movies (cast roles, avoiding duplicates if already shown in directed section)
    for (credits) |c| {
        if (c.is_cast) {
            if (!library_movie_ids.contains(c.movie_id) and !directed_movie_ids.contains(c.movie_id)) {
                if (cat.getMovieById(allocator, c.movie_id) catch null) |m| {
                    defer {
                        var mut_m = m;
                        mut_m.deinit(allocator);
                    }
                    if (m.is_present) {
                        try library_movie_ids.put(c.movie_id, {});
                        var progress_pct: ?f64 = null;
                        for (progress_list) |item| {
                            if (item.movie_id == m.id and item.duration > 0) {
                                progress_pct = (item.position / item.duration) * 100.0;
                                break;
                            }
                        }
                        try cards.appendMovieCard(&library_cards_buf, allocator, m.id, m.file_path, m.clean_name, m.title, m.poster_path, m.tmdb_id, progress_pct, is_admin, null);
                    }
                }
            }
        }
    }

    // 2. TV Shows
    const person_shows = cat.getShowsByPerson(allocator, person_id) catch &.{};
    defer {
        for (person_shows) |*s| {
            var mut = s.*;
            mut.deinit(allocator);
        }
        allocator.free(person_shows);
    }
    show_count.* = person_shows.len;

    for (person_shows) |s| {
        if (s.tmdb_id) |tid| {
            library_tmdb_ids.put(tid, {}) catch {};
        }
        try cards.appendShowCard(&library_cards_buf, allocator, s.id, s.title, s.poster_path, s.tmdb_id, is_admin);
    }

    const total_library_items = library_movie_ids.count() + person_shows.len;
    if (total_library_items == 0) {
        return allocator.dupe(u8, "");
    }

    return std.fmt.allocPrint(allocator,
        \\<div class="media-section">
        \\    <h2 class="section-title">In your library</h2>
        \\    <div class="grid movie-grid">
        \\{s}
        \\    </div>
        \\</div>
    , .{library_cards_buf.items});
}

fn renderFilmographySection(
    allocator: std.mem.Allocator,
    details_opt: ?schema.PersonDetails,
    library_tmdb_ids: *const std.AutoHashMap(i64, void),
) ![]u8 {
    const filmo_json_opt: ?[]const u8 = if (details_opt) |det| det.filmography_json else null;
    const fj = filmo_json_opt orelse return allocator.dupe(u8, "");
    if (fj.len == 0) return allocator.dupe(u8, "");

    const parsed_filmo = std.json.parseFromSlice([]tmdb.FilmographyItem, allocator, fj, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch null;
    const filmo = parsed_filmo orelse return allocator.dupe(u8, "");
    defer filmo.deinit();

    const items = filmo.value;
    if (items.len == 0) return allocator.dupe(u8, "");

    var filmo_cards_buf = std.ArrayList(u8).empty;
    defer filmo_cards_buf.deinit(allocator);

    for (items) |item| {
        const is_in_library = library_tmdb_ids.contains(item.id);

        try filmo_cards_buf.appendSlice(allocator, "        <div class=\"movie-item\">\n");

        const has_poster = item.poster_path != null and item.poster_path.?.len > 0;
        const card_class = if (has_poster) "movie-card tmdb-filmography-card has-poster" else "movie-card tmdb-filmography-card";

        const card_header = try std.fmt.allocPrint(allocator,
            \\            <div class="{s}" data-tmdb-id="{d}">
            \\
        , .{ card_class, item.id });
        defer allocator.free(card_header);
        try filmo_cards_buf.appendSlice(allocator, card_header);

        if (has_poster) {
            const poster_html = try std.fmt.allocPrint(allocator,
                \\                <img class="poster-img" loading="lazy" alt="poster" src="https://image.tmdb.org/t/p/w342{s}" onerror="this.style.display='none';this.parentElement.classList.remove('has-poster');">
                \\
            , .{item.poster_path.?});
            defer allocator.free(poster_html);
            try filmo_cards_buf.appendSlice(allocator, poster_html);
        }

        const ext_link = try std.fmt.allocPrint(allocator,
            \\                <a href="https://www.themoviedb.org/movie/{d}" target="_blank" rel="noopener noreferrer" class="play-link" title="View on TMDB"></a>
            \\                <div class="card-content">
            \\                    <div class="card-top">
            \\                        <div class="icon-wrapper">
            \\                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24">
            \\                                <path d="M15 10l5-3.07v10.14L15 14v-4z" stroke-linecap="round" stroke-linejoin="round"/>
            \\                                <rect x="4" y="6" width="11" height="12" rx="2" stroke-linecap="round" stroke-linejoin="round"/>
            \\                            </svg>
            \\                        </div>
            \\                        <span class="tmdb-external-badge" title="External link to TMDB">
            \\                            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" width="11" height="11">
            \\                                <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
            \\                                <polyline points="15 3 21 3 21 9"></polyline>
            \\                                <line x1="10" y1="14" x2="21" y2="3"></line>
            \\                            </svg>
            \\                        </span>
            \\                    </div>
            \\                </div>
            \\
        , .{item.id});
        defer allocator.free(ext_link);
        try filmo_cards_buf.appendSlice(allocator, ext_link);

        if (is_in_library) {
            try filmo_cards_buf.appendSlice(allocator,
                \\                <div class="in-library-indicator">In Library</div>
                \\
            );
        }

        try filmo_cards_buf.appendSlice(allocator, "            </div>\n            <h3 class=\"movie-title\">");
        try utils.escapeHtml(&filmo_cards_buf, allocator, item.title);
        try filmo_cards_buf.appendSlice(allocator, "</h3>\n");

        // Meta line (year • role)
        var meta_line_buf = std.ArrayList(u8).empty;
        defer meta_line_buf.deinit(allocator);

        const year = if (item.release_date) |rd| (if (rd.len >= 4) rd[0..4] else rd) else "";
        const role = item.role orelse "";

        if (year.len > 0 and role.len > 0) {
            const meta_str = try std.fmt.allocPrint(allocator, "{s} • {s}", .{ year, role });
            defer allocator.free(meta_str);
            try meta_line_buf.appendSlice(allocator, meta_str);
        } else if (year.len > 0) {
            try meta_line_buf.appendSlice(allocator, year);
        } else if (role.len > 0) {
            try meta_line_buf.appendSlice(allocator, role);
        }

        if (meta_line_buf.items.len > 0) {
            try filmo_cards_buf.appendSlice(allocator, "            <div class=\"movie-card-meta\">");
            try utils.escapeHtml(&filmo_cards_buf, allocator, meta_line_buf.items);
            try filmo_cards_buf.appendSlice(allocator, "</div>\n");
        }

        try filmo_cards_buf.appendSlice(allocator, "        </div>\n");
    }

    if (filmo_cards_buf.items.len == 0) return allocator.dupe(u8, "");

    return std.fmt.allocPrint(allocator,
        \\<div class="media-section">
        \\    <h2 class="section-title">Filmography <span class="section-count">({d})</span></h2>
        \\    <div class="horizontal-scroll-row">
        \\{s}
        \\    </div>
        \\</div>
    , .{ items.len, filmo_cards_buf.items });
}
