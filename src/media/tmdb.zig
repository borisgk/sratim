const std = @import("std");

pub const types = @import("tmdb/types.zig");
pub const TmdbMovie = types.TmdbMovie;
pub const TmdbSearchResponse = types.TmdbSearchResponse;
pub const TmdbShow = types.TmdbShow;
pub const TmdbShowSearchResponse = types.TmdbShowSearchResponse;
pub const TmdbEpisode = types.TmdbEpisode;

pub const client = @import("tmdb/client.zig");
pub const movies = @import("tmdb/movies.zig");
pub const shows = @import("tmdb/shows.zig");
pub const episodes = @import("tmdb/episodes.zig");
pub const images = @import("tmdb/images.zig");

pub const searchMovie = movies.searchMovie;
pub const searchShow = shows.searchShow;
pub const fetchEpisode = episodes.fetchEpisode;
pub const downloadImages = images.downloadImages;

pub fn parseYearAndCleanName(allocator: std.mem.Allocator, raw_name: []const u8) !struct { clean: []const u8, year: ?[]const u8 } {
    var year_idx: ?usize = null;
    var i: usize = 0;
    while (i + 4 <= raw_name.len) : (i += 1) {
        const slice = raw_name[i .. i + 4];
        var is_digit = true;
        for (slice) |c_val| {
            if (!std.ascii.isDigit(c_val)) {
                is_digit = false;
                break;
            }
        }
        if (is_digit) {
            const year_val = try std.fmt.parseInt(u32, slice, 10);
            if (year_val >= 1800 and year_val <= 2100) {
                year_idx = i;
                break;
            }
        }
    }

    if (year_idx) |idx| {
        var name_end = idx;
        while (name_end > 0) {
            const last_char = raw_name[name_end - 1];
            if (last_char == ' ' or last_char == '.' or last_char == '(' or last_char == '[' or last_char == '-') {
                name_end -= 1;
            } else {
                break;
            }
        }

        const clean = std.mem.trim(u8, raw_name[0..name_end], " \t\r\n.-_");
        const clean_dupe = try allocator.dupe(u8, clean);
        std.mem.replaceScalar(u8, clean_dupe, '.', ' ');
        std.mem.replaceScalar(u8, clean_dupe, '_', ' ');

        const year = raw_name[idx .. idx + 4];

        return .{
            .clean = clean_dupe,
            .year = try allocator.dupe(u8, year),
        };
    }

    const clean = std.mem.trim(u8, raw_name, " \t\r\n.-_");
    const clean_dupe = try allocator.dupe(u8, clean);
    std.mem.replaceScalar(u8, clean_dupe, '.', ' ');
    std.mem.replaceScalar(u8, clean_dupe, '_', ' ');

    return .{
        .clean = clean_dupe,
        .year = null,
    };
}

test "parseYearAndCleanName tests" {
    const allocator = std.testing.allocator;

    {
        const res = try parseYearAndCleanName(allocator, "Inception (2010)");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expectEqualStrings("2010", res.year.?);
    }

    {
        const res = try parseYearAndCleanName(allocator, "Inception.2010.1080p");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expectEqualStrings("2010", res.year.?);
    }

    {
        const res = try parseYearAndCleanName(allocator, "Inception");
        defer allocator.free(res.clean);
        defer if (res.year) |y| allocator.free(y);
        try std.testing.expectEqualStrings("Inception", res.clean);
        try std.testing.expect(res.year == null);
    }
}
