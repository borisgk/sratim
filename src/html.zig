const std = @import("std");

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
pub fn generatePlayerHtml(allocator: std.mem.Allocator, file_name: []const u8, duration: f64, codec_str: []const u8, audio_tracks_json: []const u8) ![]u8 {
    const min = @as(u32, @intFromFloat(duration)) / 60;
    const sec = @as(u32, @intFromFloat(duration)) % 60;
    const time_str = try std.fmt.allocPrint(allocator, "{d}:{d:0>2}", .{ min, sec });
    defer allocator.free(time_str);

    var duration_buf: [32]u8 = undefined;
    const duration_str = try std.fmt.bufPrint(&duration_buf, "{d}", .{duration});

    const template = @embedFile("player.html");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "__TIME_STR__")) {
            try out.appendSlice(allocator, time_str);
            i += "__TIME_STR__".len;
        } else if (std.mem.startsWith(u8, template[i..], "__DURATION__")) {
            try out.appendSlice(allocator, duration_str);
            i += "__DURATION__".len;
        } else if (std.mem.startsWith(u8, template[i..], "__FILE_NAME__")) {
            try escapeForJs(&out, allocator, file_name);
            i += "__FILE_NAME__".len;
        } else if (std.mem.startsWith(u8, template[i..], "__CODEC_STR__")) {
            try out.appendSlice(allocator, codec_str);
            i += "__CODEC_STR__".len;
        } else if (std.mem.startsWith(u8, template[i..], "__AUDIO_TRACKS_JSON__")) {
            try out.appendSlice(allocator, audio_tracks_json);
            i += "__AUDIO_TRACKS_JSON__".len;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}
