const std = @import("std");
const c = @cImport({
    @cInclude("libavformat/avformat.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
});

fn appendPrint(allocator: std.mem.Allocator, list: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const str = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(str);
    try list.appendSlice(allocator, str);
}

pub fn getProbeHtml(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var fmt_ctx: ?*c.AVFormatContext = null;
    
    // Convert path to null-terminated string since FFmpeg expects C strings.
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    
    if (c.avformat_open_input(&fmt_ctx, path_z, null, null) != 0) {
        return error.OpenInputFailed;
    }
    defer c.avformat_close_input(&fmt_ctx);

    if (c.avformat_find_stream_info(fmt_ctx, null) < 0) {
        return error.FindStreamInfoFailed;
    }

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    const duration_sec = if (fmt_ctx.?.*.duration != c.AV_NOPTS_VALUE) 
                         @as(f64, @floatFromInt(fmt_ctx.?.*.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE))
                         else 0.0;
                         
    const format_name = std.mem.span(fmt_ctx.?.*.iformat.*.name);
    const bit_rate = fmt_ctx.?.*.bit_rate;

    try appendPrint(allocator, &list,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Media Info</title>
        \\    <style>
        \\        body {{ font-family: sans-serif; padding: 2rem; background: #f4f4f9; color: #333; }}
        \\        h1 {{ color: #2c3e50; }}
        \\        .container {{ background: white; padding: 2rem; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }}
        \\        .stream {{ border-top: 1px solid #eee; margin-top: 1rem; padding-top: 1rem; }}
        \\        strong {{ color: #555; }}
        \\        a {{ color: #3498db; text-decoration: none; display: inline-block; margin-bottom: 1rem; }}
        \\        a:hover {{ text-decoration: underline; }}
        \\    </style>
        \\</head>
        \\<body>
        \\    <h1>Media Information</h1>
        \\    <a href="/">&larr; Back to list</a>
        \\    <div class="container">
        \\        <h2>General</h2>
        \\        <p><strong>Format:</strong> {s}</p>
        \\        <p><strong>Duration:</strong> {d:.2} seconds</p>
        \\        <p><strong>Bitrate:</strong> {d} bps</p>
        \\        
    , .{ format_name, duration_sec, bit_rate });

    const num_streams = fmt_ctx.?.*.nb_streams;
    var i: usize = 0;
    while (i < num_streams) : (i += 1) {
        const stream = fmt_ctx.?.*.streams[i];
        const codec_par = stream.*.codecpar;
        const codec_id = codec_par.*.codec_id;
        const codec_type = codec_par.*.codec_type;
        
        const codec_desc = c.avcodec_descriptor_get(codec_id);
        const codec_name = if (codec_desc != null) std.mem.span(codec_desc.*.name) else "unknown";

        try appendPrint(allocator, &list,
            \\        <div class="stream">
            \\            <h3>Stream #{d}</h3>
            \\            <p><strong>Codec:</strong> {s}</p>
        , .{ i, codec_name });

        if (codec_type == c.AVMEDIA_TYPE_VIDEO) {
            try appendPrint(allocator, &list,
                \\            <p><strong>Type:</strong> Video</p>
                \\            <p><strong>Resolution:</strong> {d}x{d}</p>
            , .{ codec_par.*.width, codec_par.*.height });
        } else if (codec_type == c.AVMEDIA_TYPE_AUDIO) {
            try appendPrint(allocator, &list,
                \\            <p><strong>Type:</strong> Audio</p>
                \\            <p><strong>Channels:</strong> {d}</p>
                \\            <p><strong>Sample Rate:</strong> {d} Hz</p>
            , .{ codec_par.*.ch_layout.nb_channels, codec_par.*.sample_rate });
        } else if (codec_type == c.AVMEDIA_TYPE_SUBTITLE) {
            try appendPrint(allocator, &list,
                \\            <p><strong>Type:</strong> Subtitle</p>
            , .{});
        } else {
            try appendPrint(allocator, &list,
                \\            <p><strong>Type:</strong> Other</p>
            , .{});
        }
        
        try appendPrint(allocator, &list, "        </div>\n", .{});
    }

    try list.appendSlice(allocator, 
        \\    </div>
        \\</body>
        \\</html>
    );

    return list.toOwnedSlice(allocator);
}
