const std = @import("std");

const HARDCODED_TMDB_TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI0YjY4NjgwZDI3MzVlYjdiMWVkNjIwZTQwZDNiMjYxMCIsIm5iZiI6MTY5MjE5NTc4Ny41MjQsInN1YiI6IjY0ZGNkYmNiMDAxYmJkMDQxYmY0NjhlOCIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.3kiXVao5QsftRTtLu2H5mfmO8K35tCtD0siaWdeCbTw";

pub const EngineMode = enum {
    ffmpeg,
    native,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !EngineMode {
        _ = allocator;
        _ = options;
        const token = try source.next();
        switch (token) {
            .string => |str| {
                if (std.mem.eql(u8, str, "ffmpeg")) {
                    return .ffmpeg;
                }
                return .native;
            },
            else => return .native,
        }
    }
};

pub const MediaEngineConfig = struct {
    subtitles: EngineMode = .native,
    metadata: EngineMode = .native,
    streamer: EngineMode = .native,
    audio_transcoder: EngineMode = .native,
};

pub const Config = struct {

    port: u16,
    tmdb_access_token: ?[]const u8 = null,
    tmdb_proxy: ?[]const u8 = null,
    media_engine: MediaEngineConfig = .{},

    pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Config {
        const file_content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(file_content);

        const parsed = try std.json.parseFromSlice(Config, allocator, file_content, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // Dupe the string so it outlives the parser arena

        const token = if (parsed.value.tmdb_access_token) |t| try allocator.dupe(u8, t) else null;
        const proxy = if (parsed.value.tmdb_proxy) |p| try allocator.dupe(u8, p) else null;

        return .{

            .port = parsed.value.port,
            .tmdb_access_token = token,
            .tmdb_proxy = proxy,
            .media_engine = parsed.value.media_engine,
        };
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {

        if (self.tmdb_access_token) |t| allocator.free(t);
        if (self.tmdb_proxy) |p| allocator.free(p);
    }

    pub fn getTmdbToken(self: Config) []const u8 {
        if (self.tmdb_access_token) |t| {
            if (t.len > 0) return t;
        }
        return HARDCODED_TMDB_TOKEN;
    }
};
