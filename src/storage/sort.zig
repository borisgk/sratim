const std = @import("std");

/// Strips leading articles ("A ", "An ", "The ") and optional leading quotes/brackets
/// for natural media library alphabetical sorting.
///
/// Examples:
/// - "The Dark Knight" -> "Dark Knight"
/// - "A Beautiful Mind" -> "Beautiful Mind"
/// - "An American Werewolf in London" -> "American Werewolf in London"
/// - "\"The Matrix\"" -> "Matrix\""
/// - "Alien" -> "Alien" (not stripped)
/// - "The" -> "The" (not stripped)
pub fn getSortTitle(title: []const u8) []const u8 {
    const trimmed = std.mem.trimStart(u8, title, " \t\"'([«");
    var res = trimmed;
    if (std.ascii.startsWithIgnoreCase(trimmed, "the ")) {
        res = std.mem.trimStart(u8, trimmed[4..], " \t");
    } else if (std.ascii.startsWithIgnoreCase(trimmed, "an ")) {
        res = std.mem.trimStart(u8, trimmed[3..], " \t");
    } else if (std.ascii.startsWithIgnoreCase(trimmed, "a ")) {
        res = std.mem.trimStart(u8, trimmed[2..], " \t");
    }
    if (res.len == 0) return trimmed;
    return res;
}

/// Natural comparator for media titles that ignores leading articles ("A", "An", "The")
/// and performs case-insensitive alphabetical ordering, with tie-breakers on full title.
pub fn titleLessThan(a: []const u8, b: []const u8) bool {
    const sort_a = getSortTitle(a);
    const sort_b = getSortTitle(b);
    const ord = std.ascii.orderIgnoreCase(sort_a, sort_b);
    if (ord == .lt) return true;
    if (ord == .gt) return false;

    // Tie-breaker 1: compare the full original titles case-insensitively
    const full_ord = std.ascii.orderIgnoreCase(a, b);
    if (full_ord == .lt) return true;
    if (full_ord == .gt) return false;

    // Tie-breaker 2: exact byte comparison for deterministic stability
    return std.mem.order(u8, a, b) == .lt;
}

test "getSortTitle strips leading articles" {
    const testing = std.testing;

    try testing.expectEqualStrings("Dark Knight", getSortTitle("The Dark Knight"));
    try testing.expectEqualStrings("dark knight", getSortTitle("the dark knight"));
    try testing.expectEqualStrings("DARK KNIGHT", getSortTitle("THE DARK KNIGHT"));
    try testing.expectEqualStrings("Beautiful Mind", getSortTitle("A Beautiful Mind"));
    try testing.expectEqualStrings("beautiful mind", getSortTitle("a beautiful mind"));
    try testing.expectEqualStrings("American Werewolf in London", getSortTitle("An American Werewolf in London"));
    try testing.expectEqualStrings("american werewolf in london", getSortTitle("an american werewolf in london"));

    // Quotes and brackets
    try testing.expectEqualStrings("Matrix\"", getSortTitle("\"The Matrix\""));
    try testing.expectEqualStrings("Matrix'", getSortTitle("'The Matrix'"));
    try testing.expectEqualStrings("Matrix)", getSortTitle("(The Matrix)"));

    // Non-articles / preserved
    try testing.expectEqualStrings("Alien", getSortTitle("Alien"));
    try testing.expectEqualStrings("There Will Be Blood", getSortTitle("There Will Be Blood"));
    try testing.expectEqualStrings("A-Team", getSortTitle("A-Team"));
    try testing.expectEqualStrings("A.I.", getSortTitle("A.I."));
    try testing.expectEqualStrings("The", getSortTitle("The"));
    try testing.expectEqualStrings("A", getSortTitle("A"));
}

test "titleLessThan sorts naturally ignoring articles and case" {
    const testing = std.testing;

    // "The Dark Knight" sorts under D, before "Die Hard"
    try testing.expect(titleLessThan("The Dark Knight", "Die Hard"));

    // "A Beautiful Mind" sorts under B, after "Batman" but before "Blade Runner"
    try testing.expect(!titleLessThan("A Beautiful Mind", "Batman"));
    try testing.expect(titleLessThan("Batman", "A Beautiful Mind"));
    try testing.expect(titleLessThan("A Beautiful Mind", "Blade Runner"));

    // Case insensitivity: "avatar" comes before "Batman"
    try testing.expect(titleLessThan("avatar", "Batman"));

    // Sort a slice of movie titles
    const movies = [_][]const u8{
        "The Avengers",
        "Avatar",
        "A Beautiful Mind",
        "Batman",
        "The Dark Knight",
        "Die Hard",
        "Alien",
        "An Inconvenient Truth",
        "The Matrix",
    };

    var sorted: [movies.len][]const u8 = movies;
    std.sort.pdq([]const u8, &sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return titleLessThan(a, b);
        }
    }.lessThan);

    const expected = [_][]const u8{
        "Alien",
        "Avatar",
        "The Avengers", // under A ("Avengers")
        "Batman",
        "A Beautiful Mind", // under B ("Beautiful Mind")
        "The Dark Knight", // under D ("Dark Knight")
        "Die Hard",
        "An Inconvenient Truth", // under I ("Inconvenient Truth")
        "The Matrix", // under M ("Matrix")
    };

    for (sorted, expected) |actual, exp| {
        try testing.expectEqualStrings(exp, actual);
    }
}
