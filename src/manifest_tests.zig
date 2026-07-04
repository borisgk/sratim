const std = @import("std");
const testing = std.testing;
const manifest = @import("manifest.zig");

const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
});

const FfprobeData = struct {
    duration_str: []const u8,
    codecs: std.ArrayList([]const u8),
};

fn getMediaDataC(allocator: std.mem.Allocator, file_path: []const u8) !FfprobeData {
    var fmt_ctx: ?*c.AVFormatContext = null;
    const path_z = try allocator.dupeZ(u8, file_path);
    defer allocator.free(path_z);

    if (c.avformat_open_input(&fmt_ctx, path_z, null, null) != 0) {
        return error.OpenInputFailed;
    }
    defer c.avformat_close_input(&fmt_ctx);

    if (c.avformat_find_stream_info(fmt_ctx, null) < 0) {
        return error.FindStreamInfoFailed;
    }

    const duration_sec = if (fmt_ctx.?.*.duration != c.AV_NOPTS_VALUE) 
                         @as(f64, @floatFromInt(fmt_ctx.?.*.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE))
                         else 0.0;
                         
    const total_seconds: u64 = @intFromFloat(duration_sec);
    const hours = total_seconds / 3600;
    const minutes = (total_seconds % 3600) / 60;
    const seconds = total_seconds % 60;
    const expected_duration = try std.fmt.allocPrint(allocator, "PT{d}H{d}M{d}S", .{ hours, minutes, seconds });

    var codecs: std.ArrayList([]const u8) = .empty;
    
    for (0..fmt_ctx.?.*.nb_streams) |i| {
        const stream = fmt_ctx.?.*.streams[i];
        const codec_par = stream.*.codecpar;
        const codec_type = codec_par.*.codec_type;
        const codec_id = codec_par.*.codec_id;

        if (codec_type == c.AVMEDIA_TYPE_VIDEO or codec_type == c.AVMEDIA_TYPE_AUDIO) {
            const decoder = c.avcodec_find_decoder(codec_id);
            const codec_name = if (decoder != null) std.mem.span(decoder.?.*.name) else "unknown";
            
            var expected_codec_dash: []const u8 = "unknown";
            if (std.mem.eql(u8, codec_name, "h264")) {
                expected_codec_dash = "avc1.4d401e";
            } else if (std.mem.eql(u8, codec_name, "hevc")) {
                expected_codec_dash = "hev1.1.6.L93.B0";
            } else if (std.mem.eql(u8, codec_name, "aac")) {
                expected_codec_dash = "mp4a.40.2";
            } else if (std.mem.eql(u8, codec_name, "ac3")) {
                expected_codec_dash = "ac-3";
            } else if (std.mem.eql(u8, codec_name, "eac3")) {
                expected_codec_dash = "ec-3";
            }

            try codecs.append(allocator, expected_codec_dash);
        }
    }
    
    return FfprobeData{ .duration_str = expected_duration, .codecs = codecs };
}

test "test manifest generator against FFmpeg C API" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var files_to_test: std.ArrayList([]const u8) = .empty;

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);

    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".mkv")) {
            if (!std.mem.eql(u8, entry.name, "dummy_movie.mkv")) {
                try files_to_test.append(allocator, try allocator.dupe(u8, entry.name));
            }
        }
    }

    const tty_file: ?std.Io.File = std.Io.Dir.cwd().openFile(std.testing.io, "/dev/tty", .{ .mode = .write_only }) catch null;
    defer if (tty_file) |f| f.close(std.testing.io);

    for (files_to_test.items) |file_path| {
        if (tty_file) |f| {
            if (std.fmt.allocPrint(allocator, "Testing {s}... ", .{file_path})) |str| {
                defer allocator.free(str);
                f.writeStreamingAll(std.testing.io, str) catch {};
            } else |_| {}
        }

        const data = getMediaDataC(allocator, file_path) catch {
            if (tty_file) |f| f.writeStreamingAll(std.testing.io, "SKIP (probe failed)\n") catch {};
            continue;
        };

        const generated_mpd = try manifest.generateMpd(allocator, file_path, "url_param");

        if (std.mem.indexOf(u8, generated_mpd, data.duration_str) == null) {
            if (tty_file) |f| f.writeStreamingAll(std.testing.io, "FAIL (duration mismatch)\n") catch {};
            return error.TestFailed;
        }

        for (data.codecs.items) |codec| {
            if (std.mem.indexOf(u8, generated_mpd, codec) == null) {
                if (tty_file) |f| {
                    if (std.fmt.allocPrint(allocator, "FAIL (codec mismatch: {s})\n", .{codec})) |str| {
                        defer allocator.free(str);
                        f.writeStreamingAll(std.testing.io, str) catch {};
                    } else |_| {}
                }
                return error.TestFailed;
            }
        }
        
        if (tty_file) |f| f.writeStreamingAll(std.testing.io, "OK\n") catch {};
    }
}
