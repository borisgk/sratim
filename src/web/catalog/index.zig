const std = @import("std");
const template_engine = @import("../../core/template.zig");
const db_mod = @import("../../db/db.zig");
const library_mod = @import("../../db/library.zig");
const utils = @import("../utils.zig");
const build_options = @import("build_options");

const global_css: []const u8 = @embedFile("../style.css");

/// Generates the HTML catalog of libraries.
pub fn generateHtml(allocator: std.mem.Allocator, database: *db_mod.Database, is_admin: bool) ![]u8 {
    const libraries = try library_mod.getLibraries(database, allocator);
    defer {
        for (libraries) |lib| {
            allocator.free(lib.name);
            allocator.free(lib.path);
            allocator.free(lib.metadata_language);
            if (lib.ignore_patterns) |pat| allocator.free(pat);
        }
        allocator.free(libraries);
    }

    var cards_buf = std.ArrayList(u8).empty;
    defer cards_buf.deinit(allocator);

    if (libraries.len == 0) {
        try cards_buf.appendSlice(allocator,
            \\            <div class="empty-state">
            \\                <h3>No Libraries Configured</h3>
            \\                <p>Get started by adding a media folder. Click the '+' button in the bottom right corner.</p>
            \\            </div>
        );
    } else {
        for (libraries) |lib| {
            const icon_svg = switch (lib.lib_type) {
                .Movies => 
                    \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="28" height="28">
                    \\    <circle cx="12" cy="12" r="10"></circle>
                    \\    <circle cx="12" cy="12" r="2"></circle>
                    \\    <circle cx="12" cy="7" r="1.5"></circle>
                    \\    <circle cx="12" cy="17" r="1.5"></circle>
                    \\    <circle cx="7" cy="12" r="1.5"></circle>
                    \\    <circle cx="17" cy="12" r="1.5"></circle>
                    \\</svg>
                ,
                .Shows => 
                    \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="28" height="28">
                    \\    <rect x="2" y="7" width="20" height="15" rx="2" ry="2"></rect>
                    \\    <polyline points="17 2 12 7 7 2"></polyline>
                    \\</svg>
                ,
                .Other => 
                    \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="28" height="28">
                    \\    <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"></path>
                    \\</svg>
                ,
            };

            const card_start = try std.fmt.allocPrint(allocator, "            <a href=\"/library?id={d}\" class=\"library-card\">\n", .{lib.id});
            defer allocator.free(card_start);
            try cards_buf.appendSlice(allocator, card_start);

            try cards_buf.appendSlice(allocator, "                <div class=\"card-top\">\n                    <div class=\"icon-wrapper\">\n                        ");
            try cards_buf.appendSlice(allocator, icon_svg);
            try cards_buf.appendSlice(allocator, "\n                    </div>\n                    <div class=\"card-info\">\n                        <h3 class=\"library-title\">");
            try utils.escapeHtml(&cards_buf, allocator, lib.name);
            try cards_buf.appendSlice(allocator, "</h3>\n                        <span class=\"library-path\">");
            try utils.escapeHtml(&cards_buf, allocator, lib.path);
            try cards_buf.appendSlice(allocator, "</span>\n                    </div>\n                </div>\n                <div class=\"card-bottom\">\n                    <span class=\"type-badge\">");
            try cards_buf.appendSlice(allocator, lib.lib_type.toString());
            try cards_buf.appendSlice(allocator, "</span>\n                    <span class=\"browse-pill\">Browse</span>\n                </div>\n            </a>\n");
        }
    }

    const admin_link_html = if (is_admin)
        \\<a href="/admin" class="admin-btn">
        \\    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="18" height="18">
        \\        <path d="M12 15a3 3 0 100-6 3 3 0 000 6z"/>
        \\        <path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 010 2.83 2 2 0 01-2.83 0l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-2 2 2 2 0 01-2-2v-.09A1.65 1.65 0 009 19.4a1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83 0 2 2 0 010-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 01-2-2 2 2 0 012-2h.09A1.65 1.65 0 004.6 9a1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 010-2.83 2 2 0 012.83 0l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V3a2 2 0 012-2 2 2 0 012 2v.09a1.65 1.65 0 001 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 0 2 2 0 010 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9a1.65 1.65 0 001.51 1H21a2 2 0 012 2 2 2 0 01-2 2h-.09a1.65 1.65 0 00-1.51 1z"/>
        \\    </svg>
        \\    Admin
        \\</a>
    else
        "";

    return template_engine.render(allocator, @embedFile("../templates/catalog.html"), .{
        .INLINE_CSS = global_css,
        .LIBRARY_CARDS = cards_buf.items,
        .ADMIN_LINK = admin_link_html,
        .APP_VERSION = build_options.version,
    });
}
