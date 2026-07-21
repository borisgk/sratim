pub fn parseSeasonEpisode(filename: []const u8) struct { season: i32, episode: i32 } {
    var season: i32 = 0;
    var episode: i32 = 0;
    
    for (0..filename.len) |i| {
        if (filename[i] == 'S' or filename[i] == 's') {
            var s_end = i + 1;
            while (s_end < filename.len and std.ascii.isDigit(filename[s_end])) {
                s_end += 1;
            }
            if (s_end > i + 1) {
                if (s_end < filename.len and (filename[s_end] == 'E' or filename[s_end] == 'e')) {
                    var e_end = s_end + 1;
                    while (e_end < filename.len and std.ascii.isDigit(filename[e_end])) {
                        e_end += 1;
                    }
                    if (e_end > s_end + 1) {
                        season = std.fmt.parseInt(i32, filename[i + 1 .. s_end], 10) catch 0;
                        episode = std.fmt.parseInt(i32, filename[s_end + 1 .. e_end], 10) catch 0;
                        return .{ .season = season, .episode = episode };
                    }
                }
            }
        }
    }
    
    for (0..filename.len) |i| {
        if (filename[i] == 'x' or filename[i] == 'X') {
            var s_start = i;
            while (s_start > 0 and std.ascii.isDigit(filename[s_start - 1])) {
                s_start -= 1;
            }
            if (s_start < i) {
                var e_end = i + 1;
                while (e_end < filename.len and std.ascii.isDigit(filename[e_end])) {
                    e_end += 1;
                }
                if (e_end > i + 1) {
                    season = std.fmt.parseInt(i32, filename[s_start .. i], 10) catch 0;
                    episode = std.fmt.parseInt(i32, filename[i + 1 .. e_end], 10) catch 0;
                    return .{ .season = season, .episode = episode };
                }
            }
        }
    }
    
    return .{ .season = 0, .episode = 0 };
}
