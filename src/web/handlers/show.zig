const std = @import("std");
const db_mod = @import("../../db/db.zig");
const logging_mod = @import("../../db/logging.zig");
const config_mod = @import("../../config.zig");
const metadata_mod = @import("../../db/metadata.zig");
const tmdb = @import("../../media/tmdb.zig");
pub const catalog_show = @import("../catalog/show.zig");
pub const renderCastCard = catalog_show.renderCastCard;

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

pub fn handleShow(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: *const config_mod.Config,
    request: *std.http.Server.Request,
    database: *db_mod.Database,
    logs_database: *db_mod.Database,
    username: []const u8,
    is_admin: bool,
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
            } else |_| {
                metadata_mod.markShowCreditsFetched(database, show.id);
            }
        }
    }

    const episodes = try cat.getEpisodesByShow(allocator, show_id);
    defer {
        for (episodes) |*ep| {
            var mut = ep.*;
            mut.deinit(allocator);
        }
        allocator.free(episodes);
    }

    const lib_opt = try cat.getLibraryById(allocator, show.library_id);
    defer if (lib_opt) |*l| {
        var mut = l.*;
        mut.deinit(allocator);
    };

    const html = try catalog_show.renderShowPage(
        allocator,
        show,
        credits,
        episodes,
        lib_opt,
        cat,
        is_admin,
    );
    defer allocator.free(html);

    try request.respond(html, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        },
    });
}
