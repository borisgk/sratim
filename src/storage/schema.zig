const std = @import("std");

pub const LibraryType = enum {
    Movies,
    Shows,
    Other,

    pub fn toString(self: LibraryType) []const u8 {
        return switch (self) {
            .Movies => "Movies",
            .Shows => "Shows",
            .Other => "Other",
        };
    }

    pub fn fromString(str: []const u8) ?LibraryType {
        if (std.mem.eql(u8, str, "Movies")) return .Movies;
        if (std.mem.eql(u8, str, "Shows")) return .Shows;
        if (std.mem.eql(u8, str, "Other")) return .Other;
        return null;
    }
};

pub const Library = struct {
    id: i64,
    name: []const u8,
    path: []const u8,
    lib_type: LibraryType = .Other,
    is_enabled: bool = true,
    depth_limit: i32 = -1,
    scan_interval: i32 = 0,
    metadata_language: []const u8 = "en",
    ignore_patterns: ?[]const u8 = null,
    include_in_dashboard: bool = true,
    created_at: i64 = 0,
    updated_at: i64 = 0,
    last_scanned_at: ?i64 = null,

    pub fn clone(self: Library, allocator: std.mem.Allocator) !Library {
        return .{
            .id = self.id,
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
            .lib_type = self.lib_type,
            .is_enabled = self.is_enabled,
            .depth_limit = self.depth_limit,
            .scan_interval = self.scan_interval,
            .metadata_language = try allocator.dupe(u8, self.metadata_language),
            .ignore_patterns = if (self.ignore_patterns) |p| try allocator.dupe(u8, p) else null,
            .include_in_dashboard = self.include_in_dashboard,
            .created_at = self.created_at,
            .updated_at = self.updated_at,
            .last_scanned_at = self.last_scanned_at,
        };
    }

    pub fn deinit(self: *Library, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.metadata_language);
        if (self.ignore_patterns) |p| allocator.free(p);
    }
};

pub const Movie = struct {
    id: i64,
    library_id: i64,
    file_path: []const u8,
    clean_name: []const u8,
    is_present: bool = true,
    tmdb_id: ?i64 = null,
    title: ?[]const u8 = null,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    backdrop_path: ?[]const u8 = null,
    release_date: ?[]const u8 = null,
    file_size: i64 = 0,

    pub fn clone(self: Movie, allocator: std.mem.Allocator) !Movie {
        return .{
            .id = self.id,
            .library_id = self.library_id,
            .file_path = try allocator.dupe(u8, self.file_path),
            .clean_name = try allocator.dupe(u8, self.clean_name),
            .is_present = self.is_present,
            .tmdb_id = self.tmdb_id,
            .title = if (self.title) |t| try allocator.dupe(u8, t) else null,
            .overview = if (self.overview) |o| try allocator.dupe(u8, o) else null,
            .poster_path = if (self.poster_path) |p| try allocator.dupe(u8, p) else null,
            .backdrop_path = if (self.backdrop_path) |b| try allocator.dupe(u8, b) else null,
            .release_date = if (self.release_date) |r| try allocator.dupe(u8, r) else null,
            .file_size = self.file_size,
        };
    }

    pub fn deinit(self: *Movie, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.clean_name);
        if (self.title) |t| allocator.free(t);
        if (self.overview) |o| allocator.free(o);
        if (self.poster_path) |p| allocator.free(p);
        if (self.backdrop_path) |b| allocator.free(b);
        if (self.release_date) |r| allocator.free(r);
    }
};

pub const Show = struct {
    id: i64,
    library_id: i64,
    path: []const u8,
    title: []const u8,
    is_present: bool = true,
    tmdb_id: ?i64 = null,
    overview: ?[]const u8 = null,
    poster_path: ?[]const u8 = null,
    backdrop_path: ?[]const u8 = null,

    pub fn clone(self: Show, allocator: std.mem.Allocator) !Show {
        return .{
            .id = self.id,
            .library_id = self.library_id,
            .path = try allocator.dupe(u8, self.path),
            .title = try allocator.dupe(u8, self.title),
            .is_present = self.is_present,
            .tmdb_id = self.tmdb_id,
            .overview = if (self.overview) |o| try allocator.dupe(u8, o) else null,
            .poster_path = if (self.poster_path) |p| try allocator.dupe(u8, p) else null,
            .backdrop_path = if (self.backdrop_path) |b| try allocator.dupe(u8, b) else null,
        };
    }

    pub fn deinit(self: *Show, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.title);
        if (self.overview) |o| allocator.free(o);
        if (self.poster_path) |p| allocator.free(p);
        if (self.backdrop_path) |b| allocator.free(b);
    }
};

pub const Episode = struct {
    id: i64,
    show_id: i64,
    file_path: []const u8,
    season: i32 = 0,
    episode: i32 = 0,
    is_present: bool = true,
    tmdb_id: ?i64 = null,
    title: ?[]const u8 = null,
    overview: ?[]const u8 = null,
    still_path: ?[]const u8 = null,
    file_size: i64 = 0,

    pub fn clone(self: Episode, allocator: std.mem.Allocator) !Episode {
        return .{
            .id = self.id,
            .show_id = self.show_id,
            .file_path = try allocator.dupe(u8, self.file_path),
            .season = self.season,
            .episode = self.episode,
            .is_present = self.is_present,
            .tmdb_id = self.tmdb_id,
            .title = if (self.title) |t| try allocator.dupe(u8, t) else null,
            .overview = if (self.overview) |o| try allocator.dupe(u8, o) else null,
            .still_path = if (self.still_path) |s| try allocator.dupe(u8, s) else null,
            .file_size = self.file_size,
        };
    }

    pub fn deinit(self: *Episode, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        if (self.title) |t| allocator.free(t);
        if (self.overview) |o| allocator.free(o);
        if (self.still_path) |s| allocator.free(s);
    }
};

pub const User = struct {
    id: i64,
    username: []const u8,
    password_hash: []const u8,
    salt: []const u8,
    is_admin: bool = false,

    pub fn clone(self: User, allocator: std.mem.Allocator) !User {
        return .{
            .id = self.id,
            .username = try allocator.dupe(u8, self.username),
            .password_hash = try allocator.dupe(u8, self.password_hash),
            .salt = try allocator.dupe(u8, self.salt),
            .is_admin = self.is_admin,
        };
    }

    pub fn deinit(self: *User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password_hash);
        allocator.free(self.salt);
    }
};

pub const Session = struct {
    token: []const u8,
    username: []const u8,
    is_admin: bool = false,
    created_at: i64 = 0,
    expires_at: i64 = 0,

    pub fn clone(self: Session, allocator: std.mem.Allocator) !Session {
        return .{
            .token = try allocator.dupe(u8, self.token),
            .username = try allocator.dupe(u8, self.username),
            .is_admin = self.is_admin,
            .created_at = self.created_at,
            .expires_at = self.expires_at,
        };
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        allocator.free(self.username);
    }
};

pub const PlaybackProgress = struct {
    username: []const u8,
    movie_id: i64,
    position: f64,
    duration: f64,
    updated_at: i64,

    pub fn clone(self: PlaybackProgress, allocator: std.mem.Allocator) !PlaybackProgress {
        return .{
            .username = try allocator.dupe(u8, self.username),
            .movie_id = self.movie_id,
            .position = self.position,
            .duration = self.duration,
            .updated_at = self.updated_at,
        };
    }

    pub fn deinit(self: *PlaybackProgress, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

pub const EpisodePlaybackProgress = struct {
    username: []const u8,
    episode_id: i64,
    position: f64,
    duration: f64,
    updated_at: i64,

    pub fn clone(self: EpisodePlaybackProgress, allocator: std.mem.Allocator) !EpisodePlaybackProgress {
        return .{
            .username = try allocator.dupe(u8, self.username),
            .episode_id = self.episode_id,
            .position = self.position,
            .duration = self.duration,
            .updated_at = self.updated_at,
        };
    }

    pub fn deinit(self: *EpisodePlaybackProgress, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
    }
};

pub const PlaybackLog = struct {
    id: i64,
    username: []const u8,
    movie_id: i64,
    event_type: []const u8,
    position: f64,
    timestamp: i64,

    pub fn clone(self: PlaybackLog, allocator: std.mem.Allocator) !PlaybackLog {
        return .{
            .id = self.id,
            .username = try allocator.dupe(u8, self.username),
            .movie_id = self.movie_id,
            .event_type = try allocator.dupe(u8, self.event_type),
            .position = self.position,
            .timestamp = self.timestamp,
        };
    }

    pub fn deinit(self: *PlaybackLog, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.event_type);
    }
};

pub const EpisodePlaybackLog = struct {
    id: i64,
    username: []const u8,
    episode_id: i64,
    event_type: []const u8,
    position: f64,
    timestamp: i64,

    pub fn clone(self: EpisodePlaybackLog, allocator: std.mem.Allocator) !EpisodePlaybackLog {
        return .{
            .id = self.id,
            .username = try allocator.dupe(u8, self.username),
            .episode_id = self.episode_id,
            .event_type = try allocator.dupe(u8, self.event_type),
            .position = self.position,
            .timestamp = self.timestamp,
        };
    }

    pub fn deinit(self: *EpisodePlaybackLog, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.event_type);
    }
};

pub const LoginLog = struct {
    id: i64,
    username: []const u8,
    status: []const u8,
    ip_address: []const u8,
    timestamp: i64,

    pub fn clone(self: LoginLog, allocator: std.mem.Allocator) !LoginLog {
        return .{
            .id = self.id,
            .username = try allocator.dupe(u8, self.username),
            .status = try allocator.dupe(u8, self.status),
            .ip_address = try allocator.dupe(u8, self.ip_address),
            .timestamp = self.timestamp,
        };
    }

    pub fn deinit(self: *LoginLog, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.status);
        allocator.free(self.ip_address);
    }
};
