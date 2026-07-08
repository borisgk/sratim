const std = @import("std");

/// Frontend HTML markup and embedded JavaScript for the custom video player.
pub fn generatePlayerHtml(allocator: std.mem.Allocator, file_name: []const u8, duration: f64, codec_str: []const u8) ![]u8 {
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
            try out.appendSlice(allocator, file_name);
            i += "__FILE_NAME__".len;
        } else if (std.mem.startsWith(u8, template[i..], "__CODEC_STR__")) {
            try out.appendSlice(allocator, codec_str);
            i += "__CODEC_STR__".len;
        } else {
            try out.append(allocator, template[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}
