const std = @import("std");

pub const SeasonEpisode = struct {
    season: i32,
    episode: i32,
};

const cyrillic_sezon_lower = "\xd1\x81\xd0\xb5\xd0\xb7\xd0\xbe\xd0\xbd"; // "сезон"
const cyrillic_sezon_upper = "\xd0\xa1\xd0\xb5\xd0\xb7\xd0\xbe\xd0\xbd"; // "Сезон"
const cyrillic_seriya_lower = "\xd1\x81\xd0\xb5\xd1\x80\xd0\xb8\xd1\x8f"; // "серия"
const cyrillic_seriya_upper = "\xd0\xa1\xd0\xb5\xd1\x80\xd0\xb8\xd1\x8f"; // "Серия"

fn isSeparator(c: u8) bool {
    return c == ' ' or c == '.' or c == '_' or c == '-';
}

fn skipSeparators(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and isSeparator(s[i])) : (i += 1) {}
    return i;
}

fn parseDigitsAt(s: []const u8, start: usize) ?struct { val: i32, end: usize, len: usize } {
    var end = start;
    while (end < s.len and std.ascii.isDigit(s[end])) : (end += 1) {}
    if (end == start or end - start > 6) return null;
    const val = std.fmt.parseInt(i32, s[start..end], 10) catch return null;
    return .{ .val = val, .end = end, .len = end - start };
}

fn startsWithIgnoreCaseAscii(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn matchEpisodePrefix(s: []const u8, pos: usize) ?usize {
    const rest = s[pos..];
    if (startsWithIgnoreCaseAscii(rest, "episode")) {
        const after = pos + "episode".len;
        if (after < s.len and (isSeparator(s[after]) or std.ascii.isDigit(s[after]))) {
            return skipSeparators(s, after);
        }
    }
    if (startsWithIgnoreCaseAscii(rest, "ep")) {
        const after = pos + "ep".len;
        if (after < s.len and (isSeparator(s[after]) or std.ascii.isDigit(s[after]))) {
            return skipSeparators(s, after);
        }
    }
    if (rest.len >= 1 and (rest[0] == 'E' or rest[0] == 'e')) {
        const after = pos + 1;
        if (after < s.len and (isSeparator(s[after]) or std.ascii.isDigit(s[after]))) {
            return skipSeparators(s, after);
        }
    }
    if (std.mem.startsWith(u8, rest, cyrillic_seriya_lower) or std.mem.startsWith(u8, rest, cyrillic_seriya_upper)) {
        const after = pos + cyrillic_seriya_lower.len;
        if (after < s.len and (isSeparator(s[after]) or std.ascii.isDigit(s[after]))) {
            return skipSeparators(s, after);
        }
    }
    return null;
}

fn matchSeasonPrefix(s: []const u8, pos: usize) ?usize {
    const rest = s[pos..];
    if (startsWithIgnoreCaseAscii(rest, "season")) {
        const after = pos + "season".len;
        if (after < s.len and (isSeparator(s[after]) or std.ascii.isDigit(s[after]))) {
            return skipSeparators(s, after);
        }
    }
    if (std.mem.startsWith(u8, rest, cyrillic_sezon_lower) or std.mem.startsWith(u8, rest, cyrillic_sezon_upper)) {
        const after = pos + cyrillic_sezon_lower.len;
        if (after < s.len and (isSeparator(s[after]) or std.ascii.isDigit(s[after]))) {
            return skipSeparators(s, after);
        }
    }
    return null;
}

fn parseSeasonFromComponent(comp: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, comp, " ._-");
    if (trimmed.len == 0) return null;

    // 1. Check "Season 02", "Сезон 2", etc.
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (matchSeasonPrefix(trimmed, i)) |digits_pos| {
            if (parseDigitsAt(trimmed, digits_pos)) |d| {
                if (d.val >= 0 and d.val <= 99) return d.val;
            }
        }
    }

    // 2. Check "<digits> сезон" / "<digits> season"
    i = 0;
    while (i < trimmed.len) : (i += 1) {
        if (std.ascii.isDigit(trimmed[i]) and (i == 0 or !std.ascii.isAlphanumeric(trimmed[i - 1]))) {
            if (parseDigitsAt(trimmed, i)) |d| {
                const after = skipSeparators(trimmed, d.end);
                const rest = trimmed[after..];
                if (startsWithIgnoreCaseAscii(rest, "season") or
                    std.mem.startsWith(u8, rest, cyrillic_sezon_lower) or
                    std.mem.startsWith(u8, rest, cyrillic_sezon_upper))
                {
                    if (d.val >= 0 and d.val <= 99) return d.val;
                }
                i = d.end - 1;
            }
        }
    }

    // 3. Check standalone "S02" / "S2" token in folder name
    i = 0;
    while (i < trimmed.len) : (i += 1) {
        if ((trimmed[i] == 'S' or trimmed[i] == 's') and (i == 0 or !std.ascii.isAlphanumeric(trimmed[i - 1]))) {
            if (parseDigitsAt(trimmed, i + 1)) |d| {
                if (d.len <= 2 and d.val >= 0 and d.val <= 99) {
                    if (d.end == trimmed.len or !std.ascii.isAlphanumeric(trimmed[d.end])) {
                        return d.val;
                    }
                }
            }
        }
    }

    // 4. Entire folder name is 1-2 digits (e.g. "02" or "2")
    if (parseDigitsAt(trimmed, 0)) |d| {
        if (d.end == trimmed.len and d.len <= 2 and d.val >= 1 and d.val <= 99) {
            return d.val;
        }
    }

    return null;
}

fn extractFolderSeason(path_or_filename: []const u8) ?i32 {
    const dirname = std.fs.path.dirname(path_or_filename) orelse return null;
    var best: ?i32 = null;
    var it = std.mem.tokenizeAny(u8, dirname, "/\\");
    while (it.next()) |comp| {
        if (parseSeasonFromComponent(comp)) |s| {
            best = s;
        }
    }
    return best;
}

fn isCommonVideoNumber(val: i32, s: []const u8, start: usize, end: usize) bool {
    if (val == 264 or val == 265 or val == 480 or val == 576 or val == 720 or val == 1080 or val == 1440 or val == 2160 or val == 4320) {
        return true;
    }
    if (val >= 1900 and val <= 2099) return true;
    // Check prefix like "x264", "h264", "h.264", "av1"
    if (start > 0 and (s[start - 1] == 'x' or s[start - 1] == 'X' or s[start - 1] == 'h' or s[start - 1] == 'H')) {
        return true;
    }
    // Check suffix like "1080p", "720i", "10bit", "5.1", "2.0"
    if (end < s.len) {
        const next_c = std.ascii.toLower(s[end]);
        if (next_c == 'p' or next_c == 'i' or next_c == 'k' or next_c == 'b') return true;
        if (startsWithIgnoreCaseAscii(s[end..], "bit") or startsWithIgnoreCaseAscii(s[end..], "fps") or startsWithIgnoreCaseAscii(s[end..], "ch")) return true;
    }
    // Check audio channel patterns like "5.1", "2.0", "7.1"
    if (end + 1 < s.len and s[end] == '.' and std.ascii.isDigit(s[end + 1])) return true;
    if (start >= 2 and s[start - 1] == '.' and std.ascii.isDigit(s[start - 2])) return true;
    return false;
}

pub fn parseSeasonEpisode(path_or_filename: []const u8) SeasonEpisode {
    const basename = std.fs.path.basename(path_or_filename);
    const ext = std.fs.path.extension(basename);
    const stem = if (ext.len > 0 and ext.len < basename.len) basename[0 .. basename.len - ext.len] else basename;
    const folder_season = extractFolderSeason(path_or_filename);

    // 1. S<season>[sep]E<episode> (e.g. S02E01, S02.E01, S02 E01, S02-E01, S02_E01, S02Ep01)
    for (0..stem.len) |i| {
        if (stem[i] == 'S' or stem[i] == 's') {
            if (i > 0 and std.ascii.isAlphabetic(stem[i - 1])) continue;
            if (parseDigitsAt(stem, i + 1)) |s_digits| {
                if (s_digits.len <= 4 and s_digits.val >= 0 and s_digits.val <= 99) {
                    const after_s = skipSeparators(stem, s_digits.end);
                    if (after_s < stem.len) {
                        if (matchEpisodePrefix(stem, after_s)) |e_digits_pos| {
                            if (parseDigitsAt(stem, e_digits_pos)) |e_digits| {
                                if (e_digits.end == stem.len or !std.ascii.isAlphabetic(stem[e_digits.end]) or stem[e_digits.end] == 'E' or stem[e_digits.end] == 'e') {
                                    return .{ .season = s_digits.val, .episode = e_digits.val };
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. "Season <S> ... Episode/Ep <E>" or "Сезон <S> ... Серия <E>"
    for (0..stem.len) |i| {
        if (matchSeasonPrefix(stem, i)) |s_digits_pos| {
            if (parseDigitsAt(stem, s_digits_pos)) |s_digits| {
                if (s_digits.val >= 0 and s_digits.val <= 99) {
                    const after_s = skipSeparators(stem, s_digits.end);
                    if (after_s < stem.len) {
                        if (matchEpisodePrefix(stem, after_s)) |e_digits_pos| {
                            if (parseDigitsAt(stem, e_digits_pos)) |e_digits| {
                                return .{ .season = s_digits.val, .episode = e_digits.val };
                            }
                        }
                    }
                }
            }
        }
    }

    // 3. <season>x<episode> (e.g. 2x01, 02x01), bounded by non-alphanumerics and rejecting resolutions (e.g. 1920x1080)
    for (0..stem.len) |i| {
        if (stem[i] == 'x' or stem[i] == 'X') {
            var s_start = i;
            while (s_start > 0 and std.ascii.isDigit(stem[s_start - 1])) {
                s_start -= 1;
            }
            if (s_start < i and (s_start == 0 or !std.ascii.isAlphanumeric(stem[s_start - 1]))) {
                if (parseDigitsAt(stem, s_start)) |s_digits| {
                    if (parseDigitsAt(stem, i + 1)) |e_digits| {
                        const valid_end = e_digits.end == stem.len or !std.ascii.isAlphanumeric(stem[e_digits.end]);
                        if (valid_end and s_digits.len <= 2 and e_digits.len <= 3 and s_digits.val >= 1 and s_digits.val <= 99 and e_digits.val >= 1 and e_digits.val <= 999) {
                            return .{ .season = s_digits.val, .episode = e_digits.val };
                        }
                    }
                }
            }
        }
    }

    // 4. <season>-<episode> (e.g. "Доктор Хаус 03-01", "Show 02-15")
    for (0..stem.len) |i| {
        if (stem[i] == '-') {
            var s_start = i;
            while (s_start > 0 and std.ascii.isDigit(stem[s_start - 1])) {
                s_start -= 1;
            }
            if (s_start < i and (s_start == 0 or (!std.ascii.isAlphanumeric(stem[s_start - 1]) and stem[s_start - 1] != '-'))) {
                if (parseDigitsAt(stem, s_start)) |s_digits| {
                    if (parseDigitsAt(stem, i + 1)) |e_digits| {
                        const valid_end = e_digits.end == stem.len or (!std.ascii.isAlphanumeric(stem[e_digits.end]) and stem[e_digits.end] != '-');
                        if (valid_end and s_digits.len <= 2 and e_digits.len == 2 and s_digits.val >= 1 and s_digits.val <= 50 and e_digits.val >= 1 and e_digits.val <= 99) {
                            if (folder_season == null or folder_season.? == s_digits.val) {
                                return .{ .season = s_digits.val, .episode = e_digits.val };
                            }
                        }
                    }
                }
            }
        }
    }

    // 5. Explicit episode marker in filename: "E01", "Ep 01", "Episode 01", "Серия 01", or "<digits> серия"
    for (0..stem.len) |i| {
        const at_boundary = i == 0 or !std.ascii.isAlphanumeric(stem[i - 1]);
        if (at_boundary) {
            if (matchEpisodePrefix(stem, i)) |e_digits_pos| {
                if (parseDigitsAt(stem, e_digits_pos)) |e_digits| {
                    const valid_end = e_digits.end == stem.len or !std.ascii.isAlphanumeric(stem[e_digits.end]);
                    if (valid_end and e_digits.val >= 1 and e_digits.val <= 999) {
                        return .{ .season = folder_season orelse 1, .episode = e_digits.val };
                    }
                }
            }
            if (std.ascii.isDigit(stem[i])) {
                if (parseDigitsAt(stem, i)) |e_digits| {
                    const after = skipSeparators(stem, e_digits.end);
                    const rest = stem[after..];
                    if (std.mem.startsWith(u8, rest, cyrillic_seriya_lower) or std.mem.startsWith(u8, rest, cyrillic_seriya_upper)) {
                        if (e_digits.val >= 1 and e_digits.val <= 999) {
                            return .{ .season = folder_season orelse 1, .episode = e_digits.val };
                        }
                    }
                }
            }
        }
    }

    // 6. When parent folder specifies a season (e.g. "Season 02/01 - Pilot.mkv", "Season 2/01.mkv", "Season 2/Show - 05.mkv")
    if (folder_season) |f_season| {
        const trimmed_stem = std.mem.trimStart(u8, stem, " ._-");
        if (parseDigitsAt(trimmed_stem, 0)) |leading| {
            const valid_end = leading.end == trimmed_stem.len or !std.ascii.isAlphanumeric(trimmed_stem[leading.end]);
            if (valid_end) {
                if (leading.len <= 2 and leading.val >= 1 and leading.val <= 99) {
                    return .{ .season = f_season, .episode = leading.val };
                }
                if ((leading.len == 3 or leading.len == 4) and @divTrunc(leading.val, 100) == f_season) {
                    const ep = @rem(leading.val, 100);
                    if (ep >= 1 and ep <= 99) {
                        return .{ .season = f_season, .episode = ep };
                    }
                }
            }
        }

        // Look for a standalone episode number token in the stem (excluding resolutions, years, codecs)
        var candidate_ep: ?i32 = null;
        var idx: usize = 0;
        while (idx < stem.len) : (idx += 1) {
            if (std.ascii.isDigit(stem[idx]) and (idx == 0 or !std.ascii.isAlphanumeric(stem[idx - 1]))) {
                if (parseDigitsAt(stem, idx)) |d| {
                    const valid_end = d.end == stem.len or !std.ascii.isAlphanumeric(stem[d.end]);
                    if (valid_end and !isCommonVideoNumber(d.val, stem, idx, d.end)) {
                        if (d.len <= 2 and d.val >= 1 and d.val <= 99) {
                            candidate_ep = d.val;
                        } else if ((d.len == 3 or d.len == 4) and @divTrunc(d.val, 100) == f_season) {
                            const ep = @rem(d.val, 100);
                            if (ep >= 1 and ep <= 99) candidate_ep = ep;
                        }
                    }
                    idx = d.end - 1;
                }
            }
        }
        if (candidate_ep) |ep| {
            return .{ .season = f_season, .episode = ep };
        }
    }

    return .{ .season = 0, .episode = 0 };
}

test "parseSeasonEpisode standard and separated SxxExx formats" {
    try std.testing.expectEqual(SeasonEpisode{ .season = 1, .episode = 2 }, parseSeasonEpisode("Show.Name.S01E02.1080p.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 5 }, parseSeasonEpisode("show_name_s02e05.mp4"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 3 }, parseSeasonEpisode("Show.Name.S02.E03.720p.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 3, .episode = 10 }, parseSeasonEpisode("Show Name S03 E10.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 4, .episode = 1 }, parseSeasonEpisode("Show Name S04-E01.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 4, .episode = 8 }, parseSeasonEpisode("Show Name S04_E08.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 1 }, parseSeasonEpisode("Show S2Ep01.mkv"));
}

test "parseSeasonEpisode NxNN and resolution rejection" {
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 5 }, parseSeasonEpisode("Show.2x05.1920x1080.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 12, .episode = 14 }, parseSeasonEpisode("Show 12x14 720p.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 0, .episode = 0 }, parseSeasonEpisode("Movie.1920x1080.x264.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 0, .episode = 0 }, parseSeasonEpisode("Movie.1280x720.x265.mkv"));
}

test "parseSeasonEpisode dash and Cyrillic formats" {
    try std.testing.expectEqual(SeasonEpisode{ .season = 3, .episode = 1 }, parseSeasonEpisode("Season 03/Доктор Хаус 03-01.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 3, .episode = 24 }, parseSeasonEpisode("Season 03/Доктор Хаус 03-24.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 7 }, parseSeasonEpisode("Сезон 2/Серия 07.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 9 }, parseSeasonEpisode("Сезон 02/09 серия.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 5, .episode = 3 }, parseSeasonEpisode("Show Season 5 Episode 3.mkv"));
}

test "parseSeasonEpisode folder season with episode-only filenames" {
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 1 }, parseSeasonEpisode("Season 02/E01 - Pilot.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 4 }, parseSeasonEpisode("Season 2/Episode 04.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 6 }, parseSeasonEpisode("Season 2/06 - The Next One.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 11 }, parseSeasonEpisode("Season 02/11.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 2, .episode = 3 }, parseSeasonEpisode("S02/203 - Title.mkv"));
    try std.testing.expectEqual(SeasonEpisode{ .season = 3, .episode = 5 }, parseSeasonEpisode("Season 3/Show Name - 05 [1080p x265].mkv"));
}
