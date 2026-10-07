const std = @import("std");
const analytics_admin = @import("analytics_admin.zig");
const analytics_mod = @import("../../db/analytics.zig");
const engine = @import("../../storage/engine.zig");
const logs_engine = @import("../../storage/logs_engine.zig");

test "serializeReportToJson: formats correctly without buffer overflow" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var cat = engine.SratimStorage.init(allocator, io, "tmp/test_ser_cat.json", "tmp/test_ser_cat.wal", "tmp/test_ser_cat_persons");
    defer cat.deinit();

    var logs = logs_engine.LogsStorage.init(allocator, io, "tmp/test_ser_logs.json", "tmp/test_ser_logs.wal");
    defer logs.deinit();

    var report = try analytics_mod.computeReport(allocator, &cat, &logs, .d30, .watch_time, 10);
    defer report.deinit();

    report.overview.total_watch_seconds = 999999999;
    report.overview.total_plays = 888888;
    report.overview.active_viewers = 7777;
    report.overview.total_movies_watched = 6666;
    report.overview.total_episodes_watched = 5555;

    const json = try analytics_admin.serializeReportToJson(allocator, &report);
    defer allocator.free(json);

    try std.testing.expect(json.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, json, "999999999") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"top_actors\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"top_directors\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trivia\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"eras\":") != null);
}
