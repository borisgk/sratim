const std = @import("std");
pub const schema = @import("schema.zig");
pub const snapshot_mod = @import("snapshot.zig");
pub const users_mod = @import("users.zig");
pub const media_mod = @import("media.zig");
pub const credits_mod = @import("credits.zig");
pub const core = @import("core/mod.zig");

pub const SratimStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    wal_path: []const u8,
    persons_dir: []const u8,
    rwlock: std.Io.RwLock = .init,

    users: core.Table(schema.User, .{ .primary_key = "username" }),
    sessions: core.Table(schema.Session, .{ .primary_key = "token" }),
    libraries: core.Table(schema.Library, .{ .primary_key = "id", .auto_increment = true }),
    movies: core.Table(schema.Movie, .{ .primary_key = "id", .auto_increment = true }),
    shows: core.Table(schema.Show, .{ .primary_key = "id", .auto_increment = true }),
    episodes: core.Table(schema.Episode, .{ .primary_key = "id", .auto_increment = true }),
    people: core.Table(schema.Person, .{ .primary_key = "id", .auto_increment = false }),
    movie_credits: core.Table(schema.MovieCredit, .{ .primary_key = "id", .auto_increment = true }),
    show_credits: core.Table(schema.ShowCredit, .{ .primary_key = "id", .auto_increment = true }),

    next_user_id: i64 = 1,
    next_library_id: i64 = 1,
    next_movie_id: i64 = 1,
    next_show_id: i64 = 1,
    next_episode_id: i64 = 1,
    next_credit_id: i64 = 1,

    pub fn writeLock(self: *SratimStorage) void {
        self.rwlock.lockUncancelable(self.io);
    }
    pub fn writeUnlock(self: *SratimStorage) void {
        self.rwlock.unlock(self.io);
    }
    pub fn readLock(self: *SratimStorage) void {
        self.rwlock.lockSharedUncancelable(self.io);
    }
    pub fn readUnlock(self: *SratimStorage) void {
        self.rwlock.unlockShared(self.io);
    }

    pub fn now(self: *const SratimStorage) i64 {
        return std.Io.Timestamp.now(self.io, .real).toSeconds();
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, wal_path: []const u8, persons_dir: []const u8) SratimStorage {
        return .{
            .allocator = allocator,
            .io = io,
            .file_path = file_path,
            .wal_path = wal_path,
            .persons_dir = persons_dir,
            .users = core.Table(schema.User, .{ .primary_key = "username" }).init(allocator),
            .sessions = core.Table(schema.Session, .{ .primary_key = "token" }).init(allocator),
            .libraries = core.Table(schema.Library, .{ .primary_key = "id", .auto_increment = true }).init(allocator),
            .movies = core.Table(schema.Movie, .{ .primary_key = "id", .auto_increment = true }).init(allocator),
            .shows = core.Table(schema.Show, .{ .primary_key = "id", .auto_increment = true }).init(allocator),
            .episodes = core.Table(schema.Episode, .{ .primary_key = "id", .auto_increment = true }).init(allocator),
            .people = core.Table(schema.Person, .{ .primary_key = "id", .auto_increment = false }).init(allocator),
            .movie_credits = core.Table(schema.MovieCredit, .{ .primary_key = "id", .auto_increment = true }).init(allocator),
            .show_credits = core.Table(schema.ShowCredit, .{ .primary_key = "id", .auto_increment = true }).init(allocator),
        };
    }

    pub fn deinit(self: *SratimStorage) void {
        self.writeLock();
        defer self.writeUnlock();

        self.users.deinit();
        self.sessions.deinit();
        self.libraries.deinit();
        self.movies.deinit();
        self.shows.deinit();
        self.episodes.deinit();
        self.people.deinit();
        self.movie_credits.deinit();
        self.show_credits.deinit();
    }

    // Snapshot operations
    pub const snapshot = snapshot_mod.snapshot;
    pub const load = snapshot_mod.load;

    // User operations
    pub const getUser = users_mod.getUser;
    pub const createUser = users_mod.createUser;
    pub const updateUserPassword = users_mod.updateUserPassword;
    pub const deleteUser = users_mod.deleteUser;
    pub const deleteUserById = users_mod.deleteUserById;
    pub const toggleAdminRole = users_mod.toggleAdminRole;
    pub const updateUserPasswordById = users_mod.updateUserPasswordById;
    pub const listUsers = users_mod.listUsers;
    pub const countUsers = users_mod.countUsers;

    // Session operations
    pub const createSession = users_mod.createSession;
    pub const getSession = users_mod.getSession;
    pub const deleteSession = users_mod.deleteSession;
    pub const cleanupExpiredSessions = users_mod.cleanupExpiredSessions;

    // Library operations
    pub const addLibrary = media_mod.addLibrary;
    pub const getLibraries = media_mod.getLibraries;
    pub const getLibraryById = media_mod.getLibraryById;
    pub const countLibraries = media_mod.countLibraries;
    pub const updateLibraryScanTime = media_mod.updateLibraryScanTime;
    pub const renameLibrary = media_mod.renameLibrary;
    pub const deleteLibrary = media_mod.deleteLibrary;
    pub const markAllMoviesAbsent = media_mod.markAllMoviesAbsent;
    pub const markAllShowsAbsent = media_mod.markAllShowsAbsent;

    // Movie operations
    pub const addOrUpdateMovie = media_mod.addOrUpdateMovie;
    pub const getMovieById = media_mod.getMovieById;
    pub const getMoviesByLibrary = media_mod.getMoviesByLibrary;
    pub const getAllMovies = media_mod.getAllMovies;
    pub const getMoviesMissingMetadata = media_mod.getMoviesMissingMetadata;
    pub const getRecentMoviesByLibrary = media_mod.getRecentMoviesByLibrary;
    pub const linkMovieMetadata = media_mod.linkMovieMetadata;
    pub const unlinkMovieMetadata = media_mod.unlinkMovieMetadata;
    pub const countMovies = media_mod.countMovies;
    pub const countMoviesByLibrary = media_mod.countMoviesByLibrary;
    pub const countUnmatchedMovies = media_mod.countUnmatchedMovies;
    pub const totalMovieStorage = media_mod.totalMovieStorage;

    // Show & Episode operations
    pub const addOrUpdateShow = media_mod.addOrUpdateShow;
    pub const getShowById = media_mod.getShowById;
    pub const getShowsByLibrary = media_mod.getShowsByLibrary;
    pub const getAllShows = media_mod.getAllShows;
    pub const getShowsMissingMetadata = media_mod.getShowsMissingMetadata;
    pub const linkShowMetadata = media_mod.linkShowMetadata;
    pub const unlinkShowMetadata = media_mod.unlinkShowMetadata;
    pub const countShows = media_mod.countShows;
    pub const countUnmatchedShows = media_mod.countUnmatchedShows;
    pub const addOrUpdateEpisode = media_mod.addOrUpdateEpisode;
    pub const getEpisodeById = media_mod.getEpisodeById;
    pub const getEpisodesByShow = media_mod.getEpisodesByShow;
    pub const linkEpisodeMetadata = media_mod.linkEpisodeMetadata;
    pub const countEpisodes = media_mod.countEpisodes;
    pub const totalEpisodeStorage = media_mod.totalEpisodeStorage;

    // Person & Credit operations
    pub const addOrUpdatePerson = credits_mod.addOrUpdatePerson;
    pub const getPersonById = credits_mod.getPersonById;
    pub const addMovieCredit = credits_mod.addMovieCredit;
    pub const clearMovieCredits = credits_mod.clearMovieCredits;
    pub const getCreditsByMovie = credits_mod.getCreditsByMovie;
    pub const getCreditsByPerson = credits_mod.getCreditsByPerson;
    pub const getMoviesByPerson = credits_mod.getMoviesByPerson;
    pub const getMoviePeopleNamesMap = credits_mod.getMoviePeopleNamesMap;
    pub const hasMovieCredits = credits_mod.hasMovieCredits;
    pub const markMovieCreditsFetched = credits_mod.markMovieCreditsFetched;
    pub const getMoviesMissingCredits = credits_mod.getMoviesMissingCredits;
    pub const savePersonDetails = credits_mod.savePersonDetails;
    pub const updatePersonProfilePath = credits_mod.updatePersonProfilePath;
    pub const markPersonDetailsFetched = credits_mod.markPersonDetailsFetched;
    pub const getPeopleMissingDetails = credits_mod.getPeopleMissingDetails;
    pub const getPeopleNeedingRefresh = credits_mod.getPeopleNeedingRefresh;
    pub const getPersonDetails = credits_mod.getPersonDetails;
    pub const addShowCredit = credits_mod.addShowCredit;
    pub const clearShowCredits = credits_mod.clearShowCredits;
    pub const getCreditsByShow = credits_mod.getCreditsByShow;
    pub const hasShowCredits = credits_mod.hasShowCredits;
    pub const markShowCreditsFetched = credits_mod.markShowCreditsFetched;
    pub const getShowsMissingCredits = credits_mod.getShowsMissingCredits;
    pub const getShowsByPerson = credits_mod.getShowsByPerson;
};
