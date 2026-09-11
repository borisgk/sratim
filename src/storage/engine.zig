const std = @import("std");
pub const schema = @import("schema.zig");
pub const snapshot_mod = @import("snapshot.zig");
pub const users_mod = @import("users.zig");
pub const media_mod = @import("media.zig");
pub const credits_mod = @import("credits.zig");

pub const SratimStorage = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    wal_path: []const u8,
    rwlock: std.Io.RwLock = .init,

    users: std.StringHashMap(schema.User),
    sessions: std.StringHashMap(schema.Session),
    libraries: std.AutoHashMap(i64, schema.Library),
    movies: std.AutoHashMap(i64, schema.Movie),
    shows: std.AutoHashMap(i64, schema.Show),
    episodes: std.AutoHashMap(i64, schema.Episode),
    people: std.AutoHashMap(i64, schema.Person),
    movie_credits: std.AutoHashMap(i64, schema.MovieCredit),

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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8, wal_path: []const u8) SratimStorage {
        return .{
            .allocator = allocator,
            .io = io,
            .file_path = file_path,
            .wal_path = wal_path,
            .users = std.StringHashMap(schema.User).init(allocator),
            .sessions = std.StringHashMap(schema.Session).init(allocator),
            .libraries = std.AutoHashMap(i64, schema.Library).init(allocator),
            .movies = std.AutoHashMap(i64, schema.Movie).init(allocator),
            .shows = std.AutoHashMap(i64, schema.Show).init(allocator),
            .episodes = std.AutoHashMap(i64, schema.Episode).init(allocator),
            .people = std.AutoHashMap(i64, schema.Person).init(allocator),
            .movie_credits = std.AutoHashMap(i64, schema.MovieCredit).init(allocator),
        };
    }

    pub fn deinit(self: *SratimStorage) void {
        self.writeLock();
        defer self.writeUnlock();

        var u_iter = self.users.iterator();
        while (u_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.users.deinit();

        var s_iter = self.sessions.iterator();
        while (s_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.sessions.deinit();

        var l_iter = self.libraries.iterator();
        while (l_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.libraries.deinit();

        var m_iter = self.movies.iterator();
        while (m_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.movies.deinit();

        var sh_iter = self.shows.iterator();
        while (sh_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.shows.deinit();

        var ep_iter = self.episodes.iterator();
        while (ep_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.episodes.deinit();

        var p_iter = self.people.iterator();
        while (p_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.people.deinit();

        var cr_iter = self.movie_credits.iterator();
        while (cr_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.movie_credits.deinit();
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
};
