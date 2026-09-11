const std = @import("std");
const db_mod = @import("../../db/db.zig");
const metadata_mod = @import("../../db/metadata.zig");
const logging_mod = @import("../../db/logging.zig");
const cards = @import("cards.zig");

const global_css: []const u8 = @embedFile("../style.css");
const template: []const u8 = @embedFile("../templates/person.html");

pub fn generatePersonHtml(
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    person_id: i64,
    username: []const u8,
    is_admin: bool,
) ![]u8 {
    const person_opt = try metadata_mod.getPersonById(database, allocator, person_id);
    if (person_opt == null) return error.PersonNotFound;
    const person = person_opt.?;
    defer {
        var p = person;
        p.deinit(allocator);
    }

    const credits = try metadata_mod.getCreditsByPerson(database, allocator, person_id);
    defer {
        for (credits) |*c| {
            var mut_c = c.*;
            mut_c.deinit(allocator);
        }
        allocator.free(credits);
    }

    const progress_opt = logging_mod.getProgressForUser(logs_database, allocator, username) catch null;
    defer if (progress_opt) |pl| allocator.free(pl);
    const progress_list = progress_opt orelse &[_]logging_mod.ProgressInfo{};

    const cat = database.catalog orelse return error.CatalogNotConfigured;

    // Avatar HTML
    var avatar_buf = std.ArrayList(u8).empty;
    defer avatar_buf.deinit(allocator);

    if (person.profile_path) |p| {
        const av_html = try std.fmt.allocPrint(allocator,
            \\<img class="person-avatar-large" src="/images/profiles/w185{s}" alt="{s}" loading="lazy" onerror="this.style.display='none';this.nextElementSibling.style.display='flex';">
            \\<div class="person-avatar-large-placeholder" style="display:none;">
            \\    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="48" height="48">
            \\        <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
            \\        <circle cx="12" cy="7" r="4"></circle>
            \\    </svg>
            \\</div>
        , .{ p, person.name });
        defer allocator.free(av_html);
        try avatar_buf.appendSlice(allocator, av_html);
    } else {
        const av_html =
            \\<div class="person-avatar-large-placeholder">
            \\    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="48" height="48">
            \\        <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
            \\        <circle cx="12" cy="7" r="4"></circle>
            \\    </svg>
            \\</div>
        ;
        try avatar_buf.appendSlice(allocator, av_html);
    }

    // Determine roles
    var is_director = false;
    var is_actor = false;
    for (credits) |c| {
        if (!c.is_cast and (std.mem.eql(u8, c.department, "Directing") or (c.job != null and std.mem.eql(u8, c.job.?, "Director")))) {
            is_director = true;
        }
        if (c.is_cast) {
            is_actor = true;
        }
    }

    const role_str: []const u8 = if (is_director and is_actor)
        "Actor & Director"
    else if (is_director)
        "Director"
    else
        "Actor";

    // Build directed movies section
    var directed_section_buf = std.ArrayList(u8).empty;
    defer directed_section_buf.deinit(allocator);

    var directed_movie_ids = std.AutoHashMap(i64, void).init(allocator);
    defer directed_movie_ids.deinit();

    var directed_cards_buf = std.ArrayList(u8).empty;
    defer directed_cards_buf.deinit(allocator);

    for (credits) |c| {
        if (!c.is_cast and (std.mem.eql(u8, c.department, "Directing") or (c.job != null and std.mem.eql(u8, c.job.?, "Director")))) {
            if (!directed_movie_ids.contains(c.movie_id)) {
                try directed_movie_ids.put(c.movie_id, {});
                if (cat.getMovieById(allocator, c.movie_id) catch null) |m| {
                    defer {
                        var mut_m = m;
                        mut_m.deinit(allocator);
                    }
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

    if (directed_movie_ids.count() > 0) {
        const sec_header = try std.fmt.allocPrint(allocator,
            \\<div class="media-section">
            \\    <h2 class="section-title">Directed by {s}</h2>
            \\    <div class="grid movie-grid">
            \\{s}
            \\    </div>
            \\</div>
        , .{ person.name, directed_cards_buf.items });
        defer allocator.free(sec_header);
        try directed_section_buf.appendSlice(allocator, sec_header);
    }

    // Build starring movies section
    var starring_section_buf = std.ArrayList(u8).empty;
    defer starring_section_buf.deinit(allocator);

    var starring_movie_ids = std.AutoHashMap(i64, void).init(allocator);
    defer starring_movie_ids.deinit();

    var starring_cards_buf = std.ArrayList(u8).empty;
    defer starring_cards_buf.deinit(allocator);

    for (credits) |c| {
        if (c.is_cast) {
            if (!starring_movie_ids.contains(c.movie_id)) {
                try starring_movie_ids.put(c.movie_id, {});
                if (cat.getMovieById(allocator, c.movie_id) catch null) |m| {
                    defer {
                        var mut_m = m;
                        mut_m.deinit(allocator);
                    }
                    var progress_pct: ?f64 = null;
                    for (progress_list) |item| {
                        if (item.movie_id == m.id and item.duration > 0) {
                            progress_pct = (item.position / item.duration) * 100.0;
                        }
                        break;
                    }
                    try cards.appendMovieCard(&starring_cards_buf, allocator, m.id, m.file_path, m.clean_name, m.title, m.poster_path, m.tmdb_id, progress_pct, is_admin, null);
                }
            }
        }
    }

    if (starring_movie_ids.count() > 0) {
        const sec_title: []const u8 = if (directed_movie_ids.count() > 0) "Starring Roles" else "Movies in your library";
        const sec_header = try std.fmt.allocPrint(allocator,
            \\<div class="media-section">
            \\    <h2 class="section-title">{s}</h2>
            \\    <div class="grid movie-grid">
            \\{s}
            \\    </div>
            \\</div>
        , .{ sec_title, starring_cards_buf.items });
        defer allocator.free(sec_header);
        try starring_section_buf.appendSlice(allocator, sec_header);
    }

    var total_unique_movies = std.AutoHashMap(i64, void).init(allocator);
    defer total_unique_movies.deinit();
    var d_it = directed_movie_ids.keyIterator();
    while (d_it.next()) |k| try total_unique_movies.put(k.*, {});
    var s_it = starring_movie_ids.keyIterator();
    while (s_it.next()) |k| try total_unique_movies.put(k.*, {});

    const total_count = total_unique_movies.count();
    const count_str = try std.fmt.allocPrint(allocator, "{d} {s}", .{
        total_count,
        if (total_count == 1) "movie" else "movies",
    });
    defer allocator.free(count_str);

    var html = std.ArrayList(u8).empty;
    defer html.deinit(allocator);
    try html.appendSlice(allocator, template);

    // Replacements
    const replacements = &[_][2][]const u8{
        .{ "__INLINE_CSS__", global_css },
        .{ "__PERSON_NAME__", person.name },
        .{ "__PERSON_AVATAR_HTML__", avatar_buf.items },
        .{ "__PERSON_ROLE__", role_str },
        .{ "__MOVIES_COUNT__", count_str },
        .{ "__PERSON_DIRECTED_SECTION__", directed_section_buf.items },
        .{ "__PERSON_STARRING_SECTION__", starring_section_buf.items },
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
