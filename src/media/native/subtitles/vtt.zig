const std = @import("std");

pub fn formatVttTime(writer: anytype, total_seconds: f64) !void {
    const sec_val = if (total_seconds < 0) 0.0 else total_seconds;
    const total_ms: u64 = @intFromFloat(sec_val * 1000.0);
    const hours = total_ms / (3600 * 1000);
    const mins = (total_ms % (3600 * 1000)) / (60 * 1000);
    const secs = (total_ms % (60 * 1000)) / 1000;
    const ms = total_ms % 1000;

    try writer.print("{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{ hours, mins, secs, ms });
}

pub fn cleanMovText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, raw_sample: []const u8) !void {
    if (raw_sample.len < 2) return;
    const text_len: usize = @intCast(std.mem.readInt(u16, raw_sample[0..2], .big));
    if (text_len == 0) return;
    const available_text_len = @min(text_len, raw_sample.len - 2);
    const text_slice = raw_sample[2 .. 2 + available_text_len];

    var i: usize = 0;
    while (i < text_slice.len) {
        if (text_slice[i] == '\r') {
            if (i + 1 < text_slice.len and text_slice[i + 1] == '\n') {
                try out.append(allocator, '\n');
                i += 2;
            } else {
                try out.append(allocator, '\n');
                i += 1;
            }
        } else if (text_slice[i] != 0) {
            try out.append(allocator, text_slice[i]);
            i += 1;
        } else {
            i += 1;
        }
    }
}

pub fn cleanAssText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ass_raw: []const u8) !void {
    var text = std.mem.trim(u8, ass_raw, " \t\r\n\x00");
    if (text.len == 0) return;

    var is_dialogue_prefix = false;

    if (text.len >= 9 and std.ascii.eqlIgnoreCase(text[0..9], "dialogue:")) {
        text = std.mem.trimStart(u8, text[9..], " \t");
        is_dialogue_prefix = true;
    } else if (text.len >= 8 and std.ascii.eqlIgnoreCase(text[0..8], "comment:")) {
        text = std.mem.trimStart(u8, text[8..], " \t");
        is_dialogue_prefix = true;
    }

    if (is_dialogue_prefix) {
        var commas: usize = 0;
        for (text, 0..) |ch, idx| {
            if (ch == ',') {
                commas += 1;
                if (commas == 9) {
                    text = text[idx + 1 ..];
                    break;
                }
            }
        }
    } else {
        var commas: usize = 0;
        var eighth_comma_idx: ?usize = null;

        for (text, 0..) |ch, idx| {
            if (ch == ',') {
                commas += 1;
                if (commas == 8) {
                    eighth_comma_idx = idx;
                    break;
                }
            }
        }

        if (eighth_comma_idx) |idx| {
            const prefix = text[0..idx];
            if (std.mem.indexOf(u8, prefix, "Default") != null or
                std.mem.indexOf(u8, prefix, "0,0,0") != null or
                std.mem.indexOf(u8, prefix, "0:00:") != null)
            {
                text = text[idx + 1 ..];
            }
        }
    }

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            while (i < text.len and text[i] != '}') : (i += 1) {}
            if (i < text.len) i += 1;
        } else if (i + 1 < text.len and text[i] == '\\' and (text[i + 1] == 'N' or text[i + 1] == 'n')) {
            try out.append(allocator, '\n');
            i += 2;
        } else if (i + 1 < text.len and text[i] == '\\' and (text[i + 1] == 'h' or text[i + 1] == 'H')) {
            try out.append(allocator, ' ');
            i += 2;
        } else {
            try out.append(allocator, text[i]);
            i += 1;
        }
    }
}

test "formatVttTime" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try formatVttTime(&aw.writer, 3661.543);
    try std.testing.expectEqualStrings("01:01:01.543", aw.written());
}

test "cleanAssText" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const raw = "Dialogue: 0,0:01:00.00,0:01:05.00,Default,,0,0,0,,{\\an8}Hello\\NWorld!";
    try cleanAssText(&out, std.testing.allocator, raw);
    try std.testing.expectEqualStrings("Hello\nWorld!", out.items);
}

test "cleanMovText" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    // 2-byte big endian length 13 (0x000D) + "Hello\r\nWorld!"
    const raw = "\x00\x0DHello\r\nWorld!";
    try cleanMovText(&out, std.testing.allocator, raw);
    try std.testing.expectEqualStrings("Hello\nWorld!", out.items);
}
