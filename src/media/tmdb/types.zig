pub const TmdbMovie = struct {
    id: i64,
    title: []const u8,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    backdrop_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
};

pub const TmdbSearchResponse = struct {
    results: []TmdbMovie,
};

pub const TmdbShow = struct {
    id: i64,
    name: []const u8,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    backdrop_path: ?[]const u8 = null,
    first_air_date: ?[]const u8 = null,
};

pub const TmdbShowSearchResponse = struct {
    results: []TmdbShow,
};

pub const TmdbEpisode = struct {
    id: i64,
    name: []const u8,
    overview: ?[]const u8 = null,
    still_path: ?[]const u8 = null,
};
