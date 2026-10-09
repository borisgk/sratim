const std = @import("std");
const cards = @import("cards.zig");

test "appendMovieCard generates valid HTML without errors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    // Test with all options populated (poster, progress, admin, search terms)
    try cards.appendMovieCard(
        &buf,
        alloc,
        12345,
        "/movies/Test Movie (2024)/test.mkv",
        "Test Movie",
        "Test Movie (Hebrew Title)",
        "/poster123.jpg",
        99999,
        45.5,
        true,
        "director actor",
    );

    try testing.expect(buf.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, buf.items, "data-id=\"12345\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "data-tmdb-id=\"99999\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "has-poster") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "src=\"/images/posters/w185/poster123.jpg\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/details?id=12345\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "context-menu-btn") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Lookup Metadata") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "width: 45.5%;") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Test Movie (Hebrew Title)") != null);

    // Test non-admin, no poster, no progress
    buf.clearRetainingCapacity();
    try cards.appendMovieCard(
        &buf,
        alloc,
        67890,
        null,
        "Simple Movie",
        null,
        null,
        null,
        null,
        false,
        null,
    );

    try testing.expect(buf.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, buf.items, "data-id=\"67890\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "has-poster") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "context-menu-btn") == null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Simple Movie") != null);
}

test "appendShowCard generates valid HTML without errors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try cards.appendShowCard(
        &buf,
        alloc,
        42,
        "Breaking Show",
        "/show_poster.jpg",
        54321,
        true,
    );

    try testing.expect(buf.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, buf.items, "data-id=\"42\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "data-tmdb-id=\"54321\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/show?id=42\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Breaking Show") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "context-menu-btn") != null);

    // Non-admin
    buf.clearRetainingCapacity();
    try cards.appendShowCard(
        &buf,
        alloc,
        43,
        "Another Show",
        null,
        null,
        false,
    );

    try testing.expect(buf.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, buf.items, "data-id=\"43\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "context-menu-btn") == null);
}

test "appendEpisodeRecentCard generates valid HTML without errors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(alloc);

    try cards.appendEpisodeRecentCard(
        &buf,
        alloc,
        777,
        "Epic Series",
        "S01E05 - The Finale",
        "/ep_poster.jpg",
        "S1:E5",
        88.2,
    );

    try testing.expect(buf.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, buf.items, "data-id=\"777\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "href=\"/player?episode_id=777\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "Epic Series") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "S01E05 - The Finale") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "S1:E5") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "width: 88.2%;") != null);
}
