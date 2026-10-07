const std = @import("std");
const config_mod = @import("../../../config.zig");
const tmdb = @import("../../../media/tmdb.zig");
const db_mod = @import("../../../db/db.zig");
const metadata_mod = @import("../../../db/metadata.zig");

pub fn handleApiPersonRefresh(
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    io: std.Io,
    database: *db_mod.Database,
    config: *const config_mod.Config,
    resp_buf: *[8192]u8,
) !void {
    _ = resp_buf;
    const token = config.getTmdbToken();
    if (token.len == 0) {
        request.respond("TMDB Access Token is empty in config.json", .{ .status = .bad_request }) catch return;
        return;
    }

    var person_id_str: []const u8 = "";
    if (std.mem.indexOf(u8, request.head.target, "?")) |q_idx| {
        const params = request.head.target[q_idx + 1 ..];
        var it = std.mem.splitScalar(u8, params, '&');
        while (it.next()) |param| {
            if (std.mem.startsWith(u8, param, "id=")) {
                person_id_str = param[3..];
            }
        }
    }

    if (person_id_str.len == 0) {
        request.respond("Missing id parameter", .{ .status = .bad_request }) catch return;
        return;
    }

    const person_id = std.fmt.parseInt(i64, person_id_str, 10) catch {
        request.respond("Invalid id parameter", .{ .status = .bad_request }) catch return;
        return;
    };

    const person_opt = metadata_mod.getPersonById(database, allocator, person_id) catch null;
    if (person_opt == null) {
        request.respond("Person not found", .{ .status = .not_found }) catch return;
        return;
    }
    var person = person_opt.?;
    defer person.deinit(allocator);

    if (tmdb.fetchPersonDetails(allocator, io, person.id, token, config.tmdb_proxy)) |details_parsed| {
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
            std.debug.print("API Person Refresh error saving details: {}\n", .{err});
            request.respond("Failed to save person details", .{ .status = .internal_server_error }) catch return;
            return;
        };

        if (d.profile_path) |prof| {
            metadata_mod.updatePersonProfilePath(database, person.id, prof) catch {};
            tmdb.downloadProfileImage(allocator, io, prof, config.tmdb_proxy) catch {};
        } else if (person.profile_path) |prof| {
            tmdb.downloadProfileImage(allocator, io, prof, config.tmdb_proxy) catch {};
        }
    } else |err| {
        std.debug.print("API Person Refresh fetch error: {}\n", .{err});
        metadata_mod.markPersonDetailsFetched(database, person.id);
    }

    var headers_buf: [2]std.http.Header = .{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "cache-control", .value = "no-cache" },
    };
    request.respond("{\"success\":true}", .{ .extra_headers = &headers_buf, .status = .ok }) catch return;
}
