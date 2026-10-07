const std = @import("std");
const db_mod = @import("../../db/db.zig");
const template_engine = @import("../../core/template.zig");
const utils = @import("../utils.zig");

const global_css: []const u8 = @embedFile("../style.css");
const show_view_template: []const u8 = @embedFile("../templates/show_view.html");

pub fn renderCastCard(
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
    try utils.escapeHtml(writer, allocator, name);
    try writer.appendSlice(allocator, "\" data-character=\"");
    if (character) |ch| {
        try utils.escapeHtml(writer, allocator, ch);
    }
    try writer.appendSlice(allocator, "\">\n            <div class=\"cast-avatar-wrapper\">\n");

    if (profile_path) |p| {
        try writer.appendSlice(allocator, "                <img class=\"cast-avatar\" src=\"/images/profiles/w185");
        try writer.appendSlice(allocator, p);
        try writer.appendSlice(allocator, "\" alt=\"");
        try utils.escapeHtml(writer, allocator, name);
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
    try utils.escapeHtml(writer, allocator, name);
    try writer.appendSlice(allocator, "</div>\n            <div class=\"cast-character\">");
    if (character) |ch| {
        try utils.escapeHtml(writer, allocator, ch);
    }
    try writer.appendSlice(allocator, "</div>\n        </a>\n");
}

pub fn renderShowPage(
    allocator: std.mem.Allocator,
    show: db_mod.schema.Show,
    credits: []const db_mod.schema.ShowCredit,
    episodes: []const db_mod.schema.Episode,
    lib_opt: ?db_mod.schema.Library,
    cat: anytype,
    is_admin: bool,
) ![]u8 {
    var cast_count: usize = 0;
    for (credits) |c| {
        if (c.is_cast) cast_count += 1;
    }
    const has_cast = cast_count > 0;

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
        try utils.escapeHtml(&seasons_buf, allocator, display_title);
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
        , .{ep_id});
        defer allocator.free(dropdown_content);
        try seasons_buf.appendSlice(allocator, dropdown_content);

        try utils.escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "\">");
        try seasons_buf.appendSlice(allocator, ep_num);
        try seasons_buf.appendSlice(allocator, " - ");
        try utils.escapeHtml(&seasons_buf, allocator, display_title);
        try seasons_buf.appendSlice(allocator, "</h3>\n");

        try seasons_buf.appendSlice(allocator, "            <p class=\"episode-overview\">");
        try utils.escapeHtml(&seasons_buf, allocator, display_overview);
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
    const lib_id_str = try std.fmt.bufPrint(&lib_id_buf, "{d}", .{show.library_id});

    const lib_name = if (lib_opt) |l| l.name else "Library";

    var backdrop_html = std.ArrayList(u8).empty;
    defer backdrop_html.deinit(allocator);

    if (show.backdrop_path != null and show.backdrop_path.?.len > 0) {
        try backdrop_html.appendSlice(allocator, "<div class=\"show-backdrop\" style=\"background-image: url('/images/backdrops/original");
        try backdrop_html.appendSlice(allocator, show.backdrop_path.?);
        try backdrop_html.appendSlice(allocator, "')\"></div>");
    }

    var admin_actions_html = std.ArrayList(u8).empty;
    defer admin_actions_html.deinit(allocator);

    var show_id_buf: [32]u8 = undefined;
    const show_id_str = try std.fmt.bufPrint(&show_id_buf, "{d}", .{show.id});

    if (is_admin) {
        try admin_actions_html.appendSlice(allocator,
            \\<div class="show-admin-actions">
            \\    <button id="refetch-cast-btn" class="action-pill-btn" data-id="
        );
        try admin_actions_html.appendSlice(allocator, show_id_str);
        try admin_actions_html.appendSlice(allocator,
            \\">
            \\        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="14" height="14">
            \\            <polyline points="23 4 23 10 17 10"></polyline>
            \\            <polyline points="1 20 1 14 7 14"></polyline>
            \\            <path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path>
            \\        </svg>
            \\        <span>Refetch Cast</span>
            \\    </button>
            \\</div>
        );
    }

    return try template_engine.render(allocator, show_view_template, .{
        .INLINE_CSS = global_css,
        .SHOW_TITLE = show.title,
        .LIBRARY_ID = lib_id_str,
        .LIBRARY_NAME = lib_name,
        .SEASON_TABS_HTML = tabs_buf.items,
        .SEASONS_HTML = seasons_buf.items,
        .CAST_HTML = cast_buf.items,
        .SHOW_BACKDROP_HTML = backdrop_html.items,
        .ADMIN_ACTIONS_HTML = admin_actions_html.items,
    });
}
