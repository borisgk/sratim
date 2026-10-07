const std = @import("std");
const template_engine = @import("../../core/template.zig");

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
            .ADMIN_ACTIONS_HTML = "",
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
            .ADMIN_ACTIONS_HTML = "",
        });
        defer allocator.free(rendered);

        try std.testing.expect(std.mem.indexOf(u8, rendered, "class=\"season-tabs-container\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "data-season=\"1\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "data-season=\"cast\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Actor Name") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Mini Series") != null);
    }
}
