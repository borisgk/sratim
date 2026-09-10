const std = @import("std");
const streamer = @import("mkv_streamer.zig");
const cues = @import("../cues.zig");

const streamMkvGeneric = streamer.streamMkvGeneric;
const canStreamMkvNatively = streamer.canStreamMkvNatively;

test "generate MKV fMP4 fragments for Sof Ha Olam Smola" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Sof Ha Olam Smola (2004).mkv",
        0.0,
        2, // Hebrew AAC track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "generate MKV fMP4 fragments with AC3 audio transcoding" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_ac3_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    // Track 1 of Sof Ha Olam Smola is AC3 (Russian)
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Sof Ha Olam Smola (2004).mkv",
        0.0,
        1, // Russian AC3 track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "generate MKV fMP4 fragments for Pressure (2026).mkv AC3" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/pressure_streamed.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    _ = streamMkvGeneric(
        allocator,
        io,
        "testvideo/Pressure (2026).mkv",
        0.0,
        2, // AC3 5.1 track
        &out_writer.interface,
        &has_error,
        20, // 20 fragments
        .native,
    ) catch return;
    try out_writer.flush();
}

test "generate MKV fMP4 fragments for Tuner.mkv with 5.1 AAC downmixing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_tuner_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Tuner.mkv",
        0.0,
        1, // 5.1 AAC track
        &out_writer.interface,
        &has_error,
        50, // 50 fragments
        .native,
    );
    try out_writer.flush();
    try std.testing.expect(!has_error);
}

test "generate MKV fMP4 fragments for Along Came Polly with AC3 5.1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_polly_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Along Came Polly (2004).mkv",
        0.0,
        1, // AC3 5.1 track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "verify canStreamMkvNatively rejects Night at the Museum DTS 5.1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const museum_path = "/Users/borisk/Movies/Sratim/Movies/Ночь в музее_Секрет гробницы.1080p. Ton.mkv";
    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_dts_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    try std.testing.expect(!canStreamMkvNatively(allocator, io, museum_path, 1));

    var has_error = false;
    const res = streamMkvGeneric(
        allocator,
        io,
        museum_path,
        0.0,
        1, // DTS 5.1 track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try std.testing.expectError(error.UnsupportedAudioCodec, res);
}

test "generate MKV fMP4 fragments for Fiddler on the Roof with AC3 2.0" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_fiddler_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    var has_error = false;
    try streamMkvGeneric(
        allocator,
        io,
        "/Users/borisk/Movies/Sratim/Movies/Fiddler.on.the.Roof.1971.1080p.BluRay.x264-DiVULGED.mkv",
        0.0,
        2, // AC3 2.0 commentary track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try out_writer.flush();
}

test "verify canStreamMkvNatively rejects Fiddler on the Roof DTS 5.1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const fiddler_path = "/Users/borisk/Movies/Sratim/Movies/Fiddler.on.the.Roof.1971.1080p.BluRay.x264-DiVULGED.mkv";
    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/mkv_test_fiddler_dts_out.mp4", .{}) catch return;
    defer out_file.close(io);

    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);

    try std.testing.expect(!canStreamMkvNatively(allocator, io, fiddler_path, 1));

    var has_error = false;
    const res = streamMkvGeneric(
        allocator,
        io,
        fiddler_path,
        0.0,
        1, // DTS 5.1 track
        &out_writer.interface,
        &has_error,
        3, // 3 fragments
        .native,
    );
    try std.testing.expectError(error.UnsupportedAudioCodec, res);
}

test "compare seek in Sof Ha Olam Smola AAC vs AC3" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const file_path = "/Users/borisk/Movies/Sratim/Movies/Sof Ha Olam Smola (2004).mkv";

    const seek_res = cues.findCueSeekPosition(io, file_path, 60.0) catch return;
    _ = seek_res;

    // Track 2: AAC (passthrough)
    {
        const out_file = std.Io.Dir.cwd().createFile(io, "tmp/seek_sof_aac.mp4", .{}) catch return;
        defer out_file.close(io);
        var out_buf: [65536]u8 = undefined;
        var out_writer = out_file.writer(io, &out_buf);
        var has_error = false;
        try streamMkvGeneric(allocator, io, file_path, 60.0, 2, &out_writer.interface, &has_error, 2, .native);
        try out_writer.flush();
    }

    // Track 1: AC3 (transcode)
    {
        const out_file = std.Io.Dir.cwd().createFile(io, "tmp/seek_sof_ac3.mp4", .{}) catch return;
        defer out_file.close(io);
        var out_buf: [65536]u8 = undefined;
        var out_writer = out_file.writer(io, &out_buf);
        var has_error = false;
        try streamMkvGeneric(allocator, io, file_path, 60.0, 1, &out_writer.interface, &has_error, 2, .native);
        try out_writer.flush();
    }
}

test "streamMkvGeneric on tests/Reacher.mkv with Pure Zig E-AC-3 transcode" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const file_path = "tests/Reacher.mkv";

    const out_file = std.Io.Dir.cwd().createFile(io, "tmp/reacher_native_eac3.mp4", .{}) catch return;
    defer out_file.close(io);
    var out_buf: [65536]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buf);
    var has_error = false;

    try streamMkvGeneric(
        allocator,
        io,
        file_path,
        0.0,
        1,
        &out_writer.interface,
        &has_error,
        2,
        .native,
    );
    try out_writer.flush();
    try std.testing.expect(!has_error);
}
