const std = @import("std");
const vtt = @import("vtt.zig");

test "formatVttTime" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try vtt.formatVttTime(&aw.writer, 3661.543);
    try std.testing.expectEqualStrings("01:01:01.543", aw.written());
}

test "cleanAssText" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    const raw = "Dialogue: 0,0:01:00.00,0:01:05.00,Default,,0,0,0,,{\\an8}Hello\\NWorld!";
    try vtt.cleanAssText(&out, std.testing.allocator, raw);
    try std.testing.expectEqualStrings("Hello\nWorld!", out.items);
}

test "cleanMovText" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);

    // 2-byte big endian length 13 (0x000D) + "Hello\r\nWorld!"
    const raw = "\x00\x0DHello\r\nWorld!";
    try vtt.cleanMovText(&out, std.testing.allocator, raw);
    try std.testing.expectEqualStrings("Hello\nWorld!", out.items);
}
