const std = @import("std");
const template_engine = @import("template.zig");

/// Escapes a string for safe injection into a JavaScript string literal inside HTML.
fn escapeForJs(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\'' => try out.appendSlice(allocator, "\\'"),
            '<' => try out.appendSlice(allocator, "\\u003c"),
            '>' => try out.appendSlice(allocator, "\\u003e"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            else => try out.append(allocator, ch),
        }
    }
}

/// Frontend HTML markup and embedded JavaScript for the custom video player.
pub fn generatePlayerHtml(
    allocator: std.mem.Allocator,
    media_query: []const u8,
    duration: f64,
    codec_str: []const u8,
    audio_tracks_json: []const u8,
    start_position: f64,
    media_title: []const u8,
    server_lan_ip: []const u8,
) ![]u8 {
    const min = @as(u32, @intFromFloat(duration)) / 60;
    const sec = @as(u32, @intFromFloat(duration)) % 60;
    const time_str = try std.fmt.allocPrint(allocator, "{d}:{d:0>2}", .{ min, sec });
    defer allocator.free(time_str);

    var title_escaped: std.ArrayList(u8) = .empty;
    defer title_escaped.deinit(allocator);
    try escapeForJs(&title_escaped, allocator, media_title);

    return template_engine.render(allocator, @embedFile("../web/templates/player.html"), .{
        .TIME_STR = time_str,
        .DURATION = duration,
        .MEDIA_QUERY = media_query,
        .CODEC_STR = codec_str,
        .AUDIO_TRACKS_JSON = audio_tracks_json,
        .START_POSITION = start_position,
        .MEDIA_TITLE = title_escaped.items,
        .SERVER_LAN_IP = server_lan_ip,
    });
}
