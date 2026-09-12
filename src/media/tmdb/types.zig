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

pub const TmdbCastMember = struct {
    id: i64,
    name: []const u8,
    character: ?[]const u8 = null,
    profile_path: ?[]const u8 = null,
    order: i32 = 0,
};

pub const TmdbCrewMember = struct {
    id: i64,
    name: []const u8,
    job: []const u8,
    department: []const u8,
    profile_path: ?[]const u8 = null,
};

pub const TmdbCreditsResponse = struct {
    id: i64,
    cast: []TmdbCastMember = &.{},
    crew: []TmdbCrewMember = &.{},
};

pub const TmdbPersonMovieCast = struct {
    id: i64,
    title: []const u8 = "",
    character: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    vote_average: ?f64 = null,
};

pub const TmdbPersonMovieCrew = struct {
    id: i64,
    title: []const u8 = "",
    job: []const u8 = "",
    department: []const u8 = "",
    poster_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    vote_average: ?f64 = null,
};

pub const TmdbPersonMovieCredits = struct {
    cast: []TmdbPersonMovieCast = &.{},
    crew: []TmdbPersonMovieCrew = &.{},
};

pub const TmdbPersonDetails = struct {
    id: i64,
    name: []const u8 = "",
    biography: ?[]const u8 = null,
    birthday: ?[]const u8 = null,
    deathday: ?[]const u8 = null,
    place_of_birth: ?[]const u8 = null,
    profile_path: ?[]const u8 = null,
    known_for_department: ?[]const u8 = null,
    imdb_id: ?[]const u8 = null,
    movie_credits: ?TmdbPersonMovieCredits = null,
};
