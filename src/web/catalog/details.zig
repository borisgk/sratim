const std = @import("std");
const db_mod = @import("../../db/db.zig");
const metadata_mod = @import("../../db/metadata.zig");
const logging_mod = @import("../../db/logging.zig");
const utils = @import("../utils.zig");

const global_css: []const u8 = @embedFile("../style.css");

pub fn generateDetailsHtml(
    allocator: std.mem.Allocator,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    movie_id: i64,
    username: []const u8,
) ![]u8 {
    const template = @embedFile("../templates/details.html");
    const info_opt = try metadata_mod.getMovieInfoById(database, allocator, movie_id);
    if (info_opt == null) return error.MovieNotFound;
    const info = info_opt.?;
    defer allocator.free(info.file_path);

    const meta = try metadata_mod.getMetadataById(database, allocator, movie_id);
    defer if (meta) |m| {
        allocator.free(m.file_path);
        allocator.free(m.title);
        if (m.overview) |ov| allocator.free(ov);
        if (m.poster_path) |pp| allocator.free(pp);
        if (m.backdrop_path) |bp| allocator.free(bp);
        if (m.release_date) |rd| allocator.free(rd);
    };

    var title: []const u8 = std.fs.path.basename(info.file_path);
    const lib_id_str = try std.fmt.allocPrint(allocator, "{d}", .{info.library_id});
    defer allocator.free(lib_id_str);
    var overview: []const u8 = "No description available.";
    var release_date: []const u8 = "";
    var poster_style_buf = std.ArrayList(u8).empty;
    defer poster_style_buf.deinit(allocator);
    var backdrop_style_buf = std.ArrayList(u8).empty;
    defer backdrop_style_buf.deinit(allocator);

    try backdrop_style_buf.appendSlice(allocator, "background-color: #0b0f19;");

    if (meta) |m| {
        if (m.title.len > 0) title = m.title;
        if (m.overview) |ov| overview = ov;
        if (m.release_date) |rd| release_date = rd;
        if (m.poster_path) |pp| {
            try poster_style_buf.appendSlice(allocator, "background-image: url('/images/posters/original");
            try poster_style_buf.appendSlice(allocator, pp);
            try poster_style_buf.appendSlice(allocator, "');");
        }
        if (m.backdrop_path) |bp| {
            backdrop_style_buf.clearRetainingCapacity();
            try backdrop_style_buf.appendSlice(allocator, "background-image: url('/images/backdrops/original");
            try backdrop_style_buf.appendSlice(allocator, bp);
            try backdrop_style_buf.appendSlice(allocator, "');");
        }
    }

    var play_url = std.ArrayList(u8).empty;
    defer play_url.deinit(allocator);
    const movie_id_str = try std.fmt.allocPrint(allocator, "/player?id={d}", .{movie_id});
    defer allocator.free(movie_id_str);
    try play_url.appendSlice(allocator, movie_id_str);

    var resume_btn_buf = std.ArrayList(u8).empty;
    defer resume_btn_buf.deinit(allocator);

    const resume_pos = logging_mod.getPlaybackProgress(logs_database, username, movie_id) catch 0.0;
    if (resume_pos > 0.0) {
        const resume_btn = try std.fmt.allocPrint(allocator, 
            \\                    <a href="{s}" class="play-btn-large resume-btn">
            \\                        <svg viewBox="0 0 24 24" fill="currentColor" width="28" height="28">
            \\                            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-2h2v2zm0-4h-2V7h2v6z" />
            \\                        </svg>
            \\                        Resume
            \\                    </a>
        , .{ play_url.items });
        defer allocator.free(resume_btn);
        try resume_btn_buf.appendSlice(allocator, resume_btn);
    }

    try play_url.appendSlice(allocator, "&start=0");

    var html = std.ArrayList(u8).empty;
    defer html.deinit(allocator);
    try html.appendSlice(allocator, template);

    // Replace placeholders
    const replacements = &[_][2][]const u8{
        .{ "__INLINE_CSS__", global_css },
        .{ "__TITLE__", title },
        .{ "__OVERVIEW__", overview },
        .{ "__RELEASE_DATE__", release_date },
        .{ "__POSTER_STYLE__", poster_style_buf.items },
        .{ "__BACKDROP_STYLE__", backdrop_style_buf.items },
        .{ "__PLAY_URL__", play_url.items },
        .{ "__RESUME_BTN__", resume_btn_buf.items },
        .{ "__LIB_ID__", lib_id_str },
    };

    var current_html = html.items;
    for (replacements) |rep| {
        const placeholder = rep[0];
        const value = rep[1];
        if (std.mem.indexOf(u8, current_html, placeholder)) |_| {
            const replaced = try std.mem.replaceOwned(u8, allocator, current_html, placeholder, value);
            // If it's not the first pass, free the old one
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
