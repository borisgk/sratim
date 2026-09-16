const std = @import("std");
const db_mod = @import("../../db/db.zig");
const logging_mod = @import("../../db/logging.zig");
const config_mod = @import("../../config.zig");
const metadata_mod = @import("../../db/metadata.zig");
const tmdb = @import("../../media/tmdb.zig");
const template_engine = @import("../../core/template.zig");
const global_css: []const u8 = @embedFile("../style.css");

var rechecked_mutex: std.atomic.Mutex = .unlocked;
var rechecked_shows: std.AutoHashMap(i64, void) = undefined;
var rechecked_shows_inited: bool = false;

fn markAndCheckShowRechecked(show_id: i64) bool {
    while (!rechecked_mutex.tryLock()) {
        std.atomic.spinLoopHint();
    }
    defer rechecked_mutex.unlock();
    if (!rechecked_shows_inited) {
        rechecked_shows = std.AutoHashMap(i64, void).init(std.heap.page_allocator);
        rechecked_shows_inited = true;
    }
    if (rechecked_shows.contains(show_id)) return true;
    rechecked_shows.put(show_id, {}) catch {};
    return false;
}

fn escapeHtml(writer: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |c| {
        switch (c) {
            '&' => try writer.appendSlice(allocator, "&amp;"),
            '<' => try writer.appendSlice(allocator, "&lt;"),
            '>' => try writer.appendSlice(allocator, "&gt;"),
            '"' => try writer.appendSlice(allocator, "&quot;"),
            '\'' => try writer.appendSlice(allocator, "&#39;"),
            else => try writer.append(allocator, c),
        }
    }
}

fn renderCastCard(
    writer: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    person_id: i64,
    name: []const u8,
    character: ?[]const u8,
    profile_path: ?[]const u8,
) !void {
    try writer.appendSlice(allocator, "        <a href=\"/person?id=");
    var id_buf: [24]u8 = undefined;
    const id_str = try std.fmt.bufPrint(&id_buf, "{d}", .{person_id});
    try writer.appendSlice(allocator, id_str);
    try writer.appendSlice(allocator, "\" class=\"cast-card\" data-name=\"");
    try escapeHtml(writer, allocator, name);
    try writer.appendSlice(allocator, "\" data-character=\"");
    if (character) |ch| {
        try escapeHtml(writer, allocator, ch);
    }
    try writer.appendSlice(allocator, "\">\n            <div class=\"cast-avatar-wrapper\">\n");

    if (profile_path) |p| {
        try writer.appendSlice(allocator, "                <img class=\"cast-avatar\" src=\"/images/profiles/w185");
        try writer.appendSlice(allocator, p);
        try writer.appendSlice(allocator, "\" alt=\"");
        try escapeHtml(writer, allocator, name);
        try writer.appendSlice(allocator, "\" loading=\"lazy\" onerror=\"if(!this.dataset.triedTmdb){this.dataset.triedTmdb='1';this.src='https://image.tmdb.org/t/p/w185");
        try writer.appendSlice(allocator, p);
        try writer.appendSlice(allocator, "';fetch('/api/images/cache?path='+encodeURIComponent('");
        try writer.appendSlice(allocator, p);
        try writer.appendSlice(allocator, "')).catch(()=>{});}else{this.style.display='none';this.nextElementSibling.style.display='flex';}\">\n");
        try writer.appendSlice(allocator, "                <div class=\"cast-avatar-placeholder\" style=\"display:none;\">\n");
        try writer.appendSlice(allocator, "                    <svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" width=\"40\" height=\"40\">\n");
        try writer.appendSlice(allocator, "                        <path d=\"M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2\"></path>\n");
        try writer.appendSlice(allocator, "                        <circle cx=\"12\" cy=\"7\" r=\"4\"></circle>\n");
        try writer.appendSlice(allocator, "                    </svg>\n                </div>\n");
    } else {
        try writer.appendSlice(allocator, "                <div class=\"cast-avatar-placeholder\">\n");
        try writer.appendSlice(allocator, "                    <svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\" width=\"40\" height=\"40\">\n");
        try writer.appendSlice(allocator, "                        <path d=\"M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2\"></path>\n");
        try writer.appendSlice(allocator, "                        <circle cx=\"12\" cy=\"7\" r=\"4\"></circle>\n");
        try writer.appendSlice(allocator, "                    </svg>\n                </div>\n");
    }

    try writer.appendSlice(allocator, "            </div>\n            <div class=\"cast-name\">");
    try escapeHtml(writer, allocator, name);
    try writer.appendSlice(allocator, "</div>\n            <div class=\"cast-character\">");
    if (character) |ch| {
        try escapeHtml(writer, allocator, ch);
    }
    try writer.appendSlice(allocator, "</div>\n        </a>\n");
}

pub fn handleShow(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
    request: *std.http.Server.Request,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    username: []const u8,
    show_id: i64,
) !void {
    _ = logs_database;
    _ = username;

    const cat = database.catalog orelse {
        try request.respond("Catalog not configured", .{ .status = .internal_server_error });
        return;
    };

    const show_opt = try cat.getShowById(allocator, show_id);
    if (show_opt == null or !show_opt.?.is_present) {
        try request.respond("Show not found", .{ .status = .not_found });
        return;
    }
    const show = show_opt.?;
    defer {
        var mut = show;
        mut.deinit(allocator);
    }

    const title = show.title;
    const backdrop_path = show.backdrop_path;
    const library_id = show.library_id;

    // Fetch credits for this show
    var credits = cat.getCreditsByShow(allocator, show_id) catch &.{};
    defer {
        for (credits) |*c| {
            var mut = c.*;
            mut.deinit(allocator);
        }
        allocator.free(credits);
    }

    var cast_count: usize = 0;
    for (credits) |c| {
        if (c.is_cast) cast_count += 1;
    }

    const is_force_refresh = std.mem.indexOf(u8, request.head.target, "refresh=1") != null;
    const is_incomplete = (cast_count <= 2 and !markAndCheckShowRechecked(show.id));
    const should_fetch = (show.tmdb_id != null and show.tmdb_id.? > 0) and (is_force_refresh or !show.credits_fetched or is_incomplete);

    // On-demand fetch from TMDB if missing or incomplete and show has a TMDB ID
    if (should_fetch) {
        const token = config.getTmdbToken();
        if (token.len > 0) {
            if (tmdb.fetchShowCredits(allocator, io, show.tmdb_id.?, token, config.tmdb_proxy)) |credits_parsed| {
                defer credits_parsed.deinit();
                metadata_mod.saveShowCredits(database, show.id, credits_parsed.value.cast, credits_parsed.value.crew) catch {};
                for (credits_parsed.value.cast[0..@min(credits_parsed.value.cast.len, 20)]) |c| {
                    if (c.profile_path) |p| {
                        tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch {};
                    }
                }
                for (credits_parsed.value.crew) |cr| {
                    if (std.mem.eql(u8, cr.job, "Director") or
                        std.mem.eql(u8, cr.job, "Creator") or
                        std.mem.eql(u8, cr.job, "Created by") or
                        std.mem.eql(u8, cr.job, "Series Director"))
                    {
                        if (cr.profile_path) |p| {
                            tmdb.downloadProfileImage(allocator, io, p, config.tmdb_proxy) catch {};
                        }
                    }
                }
                for (credits) |*c| {
                    var mut = c.*;
                    mut.deinit(allocator);
                }
                allocator.free(credits);
                credits = cat.getCreditsByShow(allocator, show_id) catch &.{};
            } else |err| {
                if (err == error.NotFound) {
                    metadata_mod.markShowCreditsFetched(database, show.id);
                }
            }
        }
    }

    cast_count = 0;
    for (credits) |c| {
        if (c.is_cast) cast_count += 1;
    }
    const has_cast = cast_count > 0;

    const episodes = try cat.getEpisodesByShow(allocator, show_id);
    defer {
        for (episodes) |*ep| {
            var mut = ep.*;
            mut.deinit(allocator);
        }
        allocator.free(episodes);
    }

    var seasons_list = std.ArrayList(i32).empty;
    defer seasons_list.deinit(allocator);

    for (episodes) |ep| {
        if (!ep.is_present) continue;
        const s = @as(i32, @intCast(ep.season));
        if (seasons_list.items.len == 0 or seasons_list.items[seasons_list.items.len - 1] != s) {
            try seasons_list.append(allocator, s);
        }
    }

    const has_multiple_seasons = seasons_list.items.len > 1;

    // Default active season: prefer Season 1 if present; otherwise first season in list
    var default_season: i32 = -1;
    if (seasons_list.items.len > 0) {
        default_season = seasons_list.items[0];
        for (seasons_list.items) |s| {
            if (s == 1) {
                default_season = 1;
                break;
            }
        }
    }

    // Generate Season Tabs HTML if multiple seasons or single season with cast
    const should_render_tabs = has_multiple_seasons or (seasons_list.items.len >= 1 and has_cast) or (seasons_list.items.len == 0 and has_cast);

    var tabs_buf = std.ArrayList(u8).empty;
    defer tabs_buf.deinit(allocator);

    if (should_render_tabs) {
        try tabs_buf.appendSlice(allocator, "<div class=\"season-tabs-container\">\n    <nav class=\"season-tabs\" role=\"tablist\" aria-label=\"Seasons\">\n");
        for (seasons_list.items) |s| {
            const is_active = (s == default_season);
            const active_class = if (is_active) " active" else "";
            const aria_selected = if (is_active) "true" else "false";

            var label_buf: [32]u8 = undefined;
            const label = if (s == 0) "Specials" else try std.fmt.bufPrint(&label_buf, "Season {d}", .{s});

            const tab_btn = try std.fmt.allocPrint(allocator,
                \\        <button type="button" role="tab" class="season-tab{s}" data-season="{d}" aria-selected="{s}" aria-controls="season-{d}">{s}</button>
                \\
            , .{ active_class, s, aria_selected, s, label });
            defer allocator.free(tab_btn);
            try tabs_buf.appendSlice(allocator, tab_btn);
        }

        if (has_cast) {
            const cast_is_active = (default_season == -1);
            const cast_active_class = if (cast_is_active) " active" else "";
            const cast_aria_selected = if (cast_is_active) "true" else "false";
            const cast_tab_btn = try std.fmt.allocPrint(allocator,
                \\        <button type="button" role="tab" class="season-tab{s}" data-season="cast" aria-selected="{s}" aria-controls="season-cast">Cast</button>
                \\
            , .{ cast_active_class, cast_aria_selected });
            defer allocator.free(cast_tab_btn);
            try tabs_buf.appendSlice(allocator, cast_tab_btn);
        }

        try tabs_buf.appendSlice(allocator, "    </nav>\n</div>\n");
    }

    var seasons_buf = std.ArrayList(u8).empty;
    defer seasons_buf.deinit(allocator);

    var current_season: i32 = -1;

    for (episodes) |ep| {
        if (!ep.is_present) continue;
        const ep_id = ep.id;
        const file_path = ep.file_path;
        const season = @as(i32, @intCast(ep.season));
        const episode = @as(i32, @intCast(ep.episode));

        if (season != current_season) {
            if (current_season != -1) {
                try seasons_buf.appendSlice(allocator, "    </div>\n</section>\n");
            }
            current_season = season;

            const is_active = (!should_render_tabs and !has_cast) or (season == default_season);
            const active_class = if (is_active) " active" else "";
            const hide_style = if (is_active) "" else " style=\"display: none;\"";

            var label_buf: [32]u8 = undefined;
            const label = if (season == 0) "Specials" else try std.fmt.bufPrint(&label_buf, "Season {d}", .{season});

            const section_header = try std.fmt.allocPrint(allocator,
                \\<section class="season-section{s}" id="season-{d}" data-season="{d}"{s}>
                \\    <h2 class="season-heading">{s}</h2>
                \\    <div class="episode-list">
                \\
            , .{ active_class, season, season, hide_style, label });
            defer allocator.free(section_header);
            try seasons_buf.appendSlice(allocator, section_header);
        }

        const ep_title_opt = ep.title;
        const ep_overview_opt = ep.overview;
        const ep_still_path_opt = ep.still_path;
        const basename = std.fs.path.basename(file_path);
        
        var buf: [16]u8 = undefined;
        const ep_num = try std.fmt.bufPrint(&buf, "Episode {d}", .{episode});

        const display_title = if (ep_title_opt) |t| t else basename;
        const display_overview = if (ep_overview_opt) |o| o else "No description available.";

        try seasons_buf.appendSlice(allocator, "    <div class=\"episode-row\" data-name=\"");
        try escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "\">\n");
        
        if (ep_still_path_opt != null and ep_still_path_opt.?.len > 0) {
            try seasons_buf.appendSlice(allocator, "        <div class=\"episode-card has-poster\">\n");
        } else {
            try seasons_buf.appendSlice(allocator, "        <div class=\"episode-card\">\n");
        }
        
        if (ep_still_path_opt != null and ep_still_path_opt.?.len > 0) {
            try seasons_buf.appendSlice(allocator, "            <img class=\"poster-img\" loading=\"lazy\" alt=\"still\" src=\"/images/backdrops/original");
            try seasons_buf.appendSlice(allocator, ep_still_path_opt.?);
            try seasons_buf.appendSlice(allocator, "\">\n");
        }

        const dropdown_content = try std.fmt.allocPrint(allocator,
            \\            <a href="/player?episode_id={d}" class="play-link"></a>
            \\            <div class="card-content">
            \\                <div class="card-top">
            \\                    <div class="icon-wrapper">
            \\                        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="24" height="24">
            \\                            <path d="M15 10l5-3.07v10.14L15 14v-4z" stroke-linecap="round" stroke-linejoin="round"/>
            \\                            <rect x="4" y="6" width="11" height="12" rx="2" stroke-linecap="round" stroke-linejoin="round"/>
            \\                        </svg>
            \\                    </div>
            \\                </div>
            \\            </div>
            \\        </div>
            \\        <div class="episode-info">
            \\            <h3 class="episode-title" title="
        , .{ ep_id });
        defer allocator.free(dropdown_content);
        try seasons_buf.appendSlice(allocator, dropdown_content);

        try escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "\">");
        try seasons_buf.appendSlice(allocator, ep_num);
        try seasons_buf.appendSlice(allocator, " - ");
        try escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "</h3>\n");
        
        try seasons_buf.appendSlice(allocator, "            <p class=\"episode-overview\">");
        try escapeHtml(&seasons_buf, allocator, display_overview);
        try seasons_buf.appendSlice(allocator, "</p>\n        </div>\n    </div>\n");
    }
    
    if (current_season != -1) {
        try seasons_buf.appendSlice(allocator, "    </div>\n</section>\n");
    } else {
        try seasons_buf.appendSlice(allocator, "<p class=\"no-episodes-msg\">No episodes found.</p>\n");
    }

    // Generate Cast HTML
    var cast_buf = std.ArrayList(u8).empty;
    defer cast_buf.deinit(allocator);

    if (has_cast) {
        const cast_is_active = (default_season == -1);
        const cast_active_class = if (cast_is_active) " active" else "";
        const cast_hide_style = if (cast_is_active) "" else " style=\"display: none;\"";

        const cast_header = try std.fmt.allocPrint(allocator,
            \\<section class="season-section show-cast-section{s}" id="season-cast" data-season="cast"{s}>
            \\    <h2 class="season-heading">Cast</h2>
            \\
        , .{ cast_active_class, cast_hide_style });
        defer allocator.free(cast_header);
        try cast_buf.appendSlice(allocator, cast_header);

        // Check for creators and directors
        var creator_count: usize = 0;
        var creators_buf = std.ArrayList(u8).empty;
        defer creators_buf.deinit(allocator);

        var seen_creators = std.AutoHashMap(i64, void).init(allocator);
        defer seen_creators.deinit();

        for (credits) |c| {
            if (!c.is_cast and c.job != null and (std.mem.eql(u8, c.job.?, "Creator") or std.mem.eql(u8, c.job.?, "Created by"))) {
                if (seen_creators.contains(c.person_id)) continue;
                try seen_creators.put(c.person_id, {});

                if (creator_count > 0) {
                    try creators_buf.appendSlice(allocator, ", ");
                }
                const link = try std.fmt.allocPrint(allocator, "<a href=\"/person?id={d}\" class=\"show-creator-link\">{s}</a>", .{ c.person_id, c.name });
                defer allocator.free(link);
                try creators_buf.appendSlice(allocator, link);
                creator_count += 1;
            }
        }

        if (creator_count > 0) {
            try cast_buf.appendSlice(allocator, "    <p class=\"show-creators\"><span class=\"show-creators-label\">Created by</span> ");
            try cast_buf.appendSlice(allocator, creators_buf.items);
            try cast_buf.appendSlice(allocator, "</p>\n");
        }

        var director_count: usize = 0;
        var directors_buf = std.ArrayList(u8).empty;
        defer directors_buf.deinit(allocator);

        var seen_directors = std.AutoHashMap(i64, void).init(allocator);
        defer seen_directors.deinit();

        for (credits) |c| {
            if (!c.is_cast and c.job != null and (std.mem.eql(u8, c.job.?, "Director") or std.mem.eql(u8, c.job.?, "Series Director"))) {
                if (seen_directors.contains(c.person_id)) continue;
                try seen_directors.put(c.person_id, {});

                if (director_count > 0) {
                    try directors_buf.appendSlice(allocator, ", ");
                }
                const link = try std.fmt.allocPrint(allocator, "<a href=\"/person?id={d}\" class=\"show-creator-link\">{s}</a>", .{ c.person_id, c.name });
                defer allocator.free(link);
                try directors_buf.appendSlice(allocator, link);
                director_count += 1;
            }
        }

        if (director_count > 0) {
            try cast_buf.appendSlice(allocator, "    <p class=\"show-creators\"><span class=\"show-creators-label\">Directed by</span> ");
            try cast_buf.appendSlice(allocator, directors_buf.items);
            try cast_buf.appendSlice(allocator, "</p>\n");
        }

        try cast_buf.appendSlice(allocator, "    <div class=\"cast-grid\">\n");

        for (credits) |c| {
            if (!c.is_cast) continue;

            var person_opt: ?db_mod.schema.Person = null;
            defer if (person_opt) |*p| p.deinit(allocator);

            var profile_path = c.profile_path;
            if (profile_path == null) {
                if (cat.getPersonById(allocator, c.person_id) catch null) |p| {
                    person_opt = p;
                    profile_path = person_opt.?.profile_path;
                }
            }

            try renderCastCard(&cast_buf, allocator, c.person_id, c.name, c.character, profile_path);
        }

        try cast_buf.appendSlice(allocator, "    </div>\n</section>\n");
    }

    var lib_id_buf: [32]u8 = undefined;
    const lib_id_str = try std.fmt.bufPrint(&lib_id_buf, "{d}", .{library_id});

    const lib_opt = try cat.getLibraryById(allocator, library_id);
    defer if (lib_opt) |*l| {
        var mut = l.*;
        mut.deinit(allocator);
    };
    const lib_name = if (lib_opt) |l| l.name else "Library";

    var backdrop_html = std.ArrayList(u8).empty;
    defer backdrop_html.deinit(allocator);

    if (backdrop_path != null and backdrop_path.?.len > 0) {
        try backdrop_html.appendSlice(allocator, "<div class=\"show-backdrop\" style=\"background-image: url('/images/backdrops/original");
        try backdrop_html.appendSlice(allocator, backdrop_path.?);
        try backdrop_html.appendSlice(allocator, "')\"></div>");
    }

    const html = try template_engine.render(allocator, @embedFile("../templates/show_view.html"), .{
        .INLINE_CSS = global_css,
        .SHOW_TITLE = title,
        .LIBRARY_ID = lib_id_str,
        .LIBRARY_NAME = lib_name,
        .SEASON_TABS_HTML = tabs_buf.items,
        .SEASONS_HTML = seasons_buf.items,
        .CAST_HTML = cast_buf.items,
        .SHOW_BACKDROP_HTML = backdrop_html.items,
    });
    defer allocator.free(html);

    try request.respond(html, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}

test "show template renders season tabs and cast when provided" {
    const allocator = std.testing.allocator;
    const template_str = @embedFile("../templates/show_view.html");

    // Multi-season render with Cast tab
    {
        const tabs_html =
            \\<div class="season-tabs-container">
            \\    <nav class="season-tabs" role="tablist" aria-label="Seasons">
            \\        <button type="button" role="tab" class="season-tab active" data-season="1" aria-selected="true" aria-controls="season-1">Season 1</button>
            \\        <button type="button" role="tab" class="season-tab" data-season="2" aria-selected="false" aria-controls="season-2">Season 2</button>
            \\        <button type="button" role="tab" class="season-tab" data-season="cast" aria-selected="false" aria-controls="season-cast">Cast</button>
            \\    </nav>
            \\</div>
        ;
        const seasons_html =
            \\<section class="season-section active" id="season-1" data-season="1">
            \\    <h2 class="season-heading">Season 1</h2>
            \\    <div class="episode-list">
            \\        <div class="episode-row" data-name="Pilot">Episode 1 - Pilot</div>
            \\    </div>
            \\</section>
            \\<section class="season-section" id="season-2" data-season="2" style="display: none;">
            \\    <h2 class="season-heading">Season 2</h2>
            \\    <div class="episode-list">
            \\        <div class="episode-row" data-name="Episode 1">Episode 1 - S2E1</div>
            \\    </div>
            \\</section>
        ;
        const cast_html =
            \\<section class="season-section show-cast-section" id="season-cast" data-season="cast" style="display: none;">
            \\    <h2 class="season-heading">Cast</h2>
            \\    <p class="show-creators"><span class="show-creators-label">Created by</span> <a href="/person?id=1" class="show-creator-link">Vince Gilligan</a></p>
            \\    <div class="cast-grid">
            \\        <a href="/person?id=17419" class="cast-card" data-name="Bryan Cranston" data-character="Walter White">
            \\            <div class="cast-avatar-wrapper"><div class="cast-avatar-placeholder"></div></div>
            \\            <div class="cast-name">Bryan Cranston</div>
            \\            <div class="cast-character">Walter White</div>
            \\        </a>
            \\    </div>
            \\</section>
        ;

        const rendered = try template_engine.render(allocator, template_str, .{
            .INLINE_CSS = "/* css */",
            .SHOW_TITLE = "Test TV Show",
            .LIBRARY_ID = "42",
            .LIBRARY_NAME = "Shows",
            .SEASON_TABS_HTML = tabs_html,
            .SEASONS_HTML = seasons_html,
            .CAST_HTML = cast_html,
            .SHOW_BACKDROP_HTML = "",
        });
        defer allocator.free(rendered);

        try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"season-tabs-container\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "data-season=\"1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "data-season=\"2\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "data-season=\"cast\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Bryan Cranston") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Walter White") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Vince Gilligan") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "switchSeason") != null);
    }

    // Single-season render with Cast tab
    {
        const tabs_html =
            \\<div class="season-tabs-container">
            \\    <nav class="season-tabs" role="tablist" aria-label="Seasons">
            \\        <button type="button" role="tab" class="season-tab active" data-season="1" aria-selected="true" aria-controls="season-1">Season 1</button>
            \\        <button type="button" role="tab" class="season-tab" data-season="cast" aria-selected="false" aria-controls="season-cast">Cast</button>
            \\    </nav>
            \\</div>
        ;
        const seasons_html =
            \\<section class="season-section active" id="season-1" data-season="1">
            \\    <h2 class="season-heading">Season 1</h2>
            \\    <div class="episode-list">
            \\        <div class="episode-row" data-name="Single Ep">Episode 1</div>
            \\    </div>
            \\</section>
        ;
        const cast_html =
            \\<section class="season-section show-cast-section" id="season-cast" data-season="cast" style="display: none;">
            \\    <h2 class="season-heading">Cast</h2>
            \\    <div class="cast-grid">
            \\        <a href="/person?id=123" class="cast-card" data-name="Actor Name" data-character="Role">
            \\            <div class="cast-avatar-wrapper"><div class="cast-avatar-placeholder"></div></div>
            \\            <div class="cast-name">Actor Name</div>
            \\            <div class="cast-character">Role</div>
            \\        </a>
            \\    </div>
            \\</section>
        ;

        const rendered = try template_engine.render(allocator, template_str, .{
            .INLINE_CSS = "/* css */",
            .SHOW_TITLE = "Mini Series",
            .LIBRARY_ID = "42",
            .LIBRARY_NAME = "Shows",
            .SEASON_TABS_HTML = tabs_html,
            .SEASONS_HTML = seasons_html,
            .CAST_HTML = cast_html,
            .SHOW_BACKDROP_HTML = "",
        });
        defer allocator.free(rendered);

        try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"season-tabs-container\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "data-season=\"1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "data-season=\"cast\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Actor Name") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Mini Series") != null);
    }
}

