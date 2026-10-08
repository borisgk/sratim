pub const library = @import("media/library.zig");
pub const movies = @import("media/movies.zig");
pub const shows = @import("media/shows.zig");

// Library operations
pub const addLibrary = library.addLibrary;
pub const getLibraries = library.getLibraries;
pub const getLibraryById = library.getLibraryById;
pub const countLibraries = library.countLibraries;
pub const updateLibraryScanTime = library.updateLibraryScanTime;
pub const renameLibrary = library.renameLibrary;
pub const deleteLibrary = library.deleteLibrary;
pub const markAllMoviesAbsent = library.markAllMoviesAbsent;
pub const markAllShowsAbsent = library.markAllShowsAbsent;

// Movie operations
pub const addOrUpdateMovie = movies.addOrUpdateMovie;
pub const getMovieById = movies.getMovieById;
pub const getMoviesByLibrary = movies.getMoviesByLibrary;
pub const getAllMovies = movies.getAllMovies;
pub const getMoviesMissingMetadata = movies.getMoviesMissingMetadata;
pub const getRecentMoviesByLibrary = movies.getRecentMoviesByLibrary;
pub const linkMovieMetadata = movies.linkMovieMetadata;
pub const unlinkMovieMetadata = movies.unlinkMovieMetadata;
pub const countMovies = movies.countMovies;
pub const countMoviesByLibrary = movies.countMoviesByLibrary;
pub const countUnmatchedMovies = movies.countUnmatchedMovies;
pub const totalMovieStorage = movies.totalMovieStorage;

// Show & Episode operations
pub const addOrUpdateShow = shows.addOrUpdateShow;
pub const getShowById = shows.getShowById;
pub const getShowsByLibrary = shows.getShowsByLibrary;
pub const getAllShows = shows.getAllShows;
pub const getShowsMissingMetadata = shows.getShowsMissingMetadata;
pub const linkShowMetadata = shows.linkShowMetadata;
pub const unlinkShowMetadata = shows.unlinkShowMetadata;
pub const countShows = shows.countShows;
pub const countUnmatchedShows = shows.countUnmatchedShows;
pub const addOrUpdateEpisode = shows.addOrUpdateEpisode;
pub const getEpisodeById = shows.getEpisodeById;
pub const getEpisodesByShow = shows.getEpisodesByShow;
pub const linkEpisodeMetadata = shows.linkEpisodeMetadata;
pub const countEpisodes = shows.countEpisodes;
pub const totalEpisodeStorage = shows.totalEpisodeStorage;
