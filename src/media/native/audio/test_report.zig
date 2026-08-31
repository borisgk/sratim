const std = @import("std");

pub const SegmentStats = struct {
    start_time: f64,
    end_time: f64,
    sample_count: usize,
    rms_native: f64,
    rms_ffmpeg: f64,
    max_abs_diff: f32,
    snr_db: f64,
    correlation: f64,
};

pub const ChannelStats = struct {
    rms_nat_l: f64,
    rms_ff_l: f64,
    corr_l: f64,
    snr_l: f64,
    rms_nat_r: f64,
    rms_ff_r: f64,
    corr_r: f64,
    snr_r: f64,
};

pub fn calculateStats(
    native: []const f32,
    ffmpeg: []const f32,
    sample_rate: u32,
    num_segments: usize,
    scale_native: f32,
    allocator: std.mem.Allocator,
) ![]SegmentStats {
    const min_len = @min(native.len, ffmpeg.len);
    const total_stereo_samples = min_len / 2;
    const seg_size_samples = (total_stereo_samples + num_segments - 1) / num_segments;

    var stats_list = std.ArrayList(SegmentStats).empty;
    errdefer stats_list.deinit(allocator);

    for (0..num_segments) |seg_idx| {
        const start_sample = seg_idx * seg_size_samples;
        if (start_sample >= total_stereo_samples) break;
        const end_sample = @min((seg_idx + 1) * seg_size_samples, total_stereo_samples);
        const count = end_sample - start_sample;
        if (count == 0) continue;

        const start_idx = start_sample * 2;
        const end_idx = end_sample * 2;

        const nat_slice = native[start_idx..end_idx];
        const ff_slice = ffmpeg[start_idx..end_idx];

        var sum_sq_nat: f64 = 0.0;
        var sum_sq_ff: f64 = 0.0;
        var sum_sq_err: f64 = 0.0;
        var dot: f64 = 0.0;
        var max_diff: f32 = 0.0;

        for (nat_slice, ff_slice) |raw_n, f| {
            const n = raw_n * scale_native;
            sum_sq_nat += @as(f64, n) * @as(f64, n);
            sum_sq_ff += @as(f64, f) * @as(f64, f);
            const err = @as(f64, n) - @as(f64, f);
            sum_sq_err += err * err;
            dot += @as(f64, n) * @as(f64, f);

            const abs_d = @abs(n - f);
            if (abs_d > max_diff) max_diff = abs_d;
        }

        const denom_corr = std.math.sqrt(sum_sq_nat * sum_sq_ff);
        const corr: f64 = if (denom_corr > 1e-15) dot / denom_corr else if (sum_sq_nat == 0 and sum_sq_ff == 0) 1.0 else 0.0;
        const snr = if (sum_sq_err > 1e-15) 10.0 * std.math.log10((sum_sq_ff + 1e-15) / sum_sq_err) else 120.0;

        const float_count = @as(f64, @floatFromInt(nat_slice.len));
        try stats_list.append(allocator, .{
            .start_time = @as(f64, @floatFromInt(start_sample)) / @as(f64, @floatFromInt(sample_rate)),
            .end_time = @as(f64, @floatFromInt(end_sample)) / @as(f64, @floatFromInt(sample_rate)),
            .sample_count = count,
            .rms_native = std.math.sqrt(sum_sq_nat / float_count),
            .rms_ffmpeg = std.math.sqrt(sum_sq_ff / float_count),
            .max_abs_diff = max_diff,
            .snr_db = snr,
            .correlation = corr,
        });
    }

    return try stats_list.toOwnedSlice(allocator);
}

pub fn calculateChannelStats(nat_aligned: []const f32, ff_aligned: []const f32, scale_native: f32) ChannelStats {
    var dot_l: f64 = 0;
    var dot_r: f64 = 0;
    var sum_sq_nat_l: f64 = 0;
    var sum_sq_ff_l: f64 = 0;
    var sum_sq_nat_r: f64 = 0;
    var sum_sq_ff_r: f64 = 0;
    var err_l: f64 = 0;
    var err_r: f64 = 0;

    var j: usize = 0;
    while (j < nat_aligned.len) : (j += 2) {
        const nl = @as(f64, nat_aligned[j] * scale_native);
        const fl = @as(f64, ff_aligned[j]);
        const nr = @as(f64, nat_aligned[j + 1] * scale_native);
        const fr = @as(f64, ff_aligned[j + 1]);

        dot_l += nl * fl;
        sum_sq_nat_l += nl * nl;
        sum_sq_ff_l += fl * fl;
        err_l += (nl - fl) * (nl - fl);

        dot_r += nr * fr;
        sum_sq_nat_r += nr * nr;
        sum_sq_ff_r += fr * fr;
        err_r += (nr - fr) * (nr - fr);
    }

    const denom_l = std.math.sqrt(sum_sq_nat_l) * std.math.sqrt(sum_sq_ff_l);
    const denom_r = std.math.sqrt(sum_sq_nat_r) * std.math.sqrt(sum_sq_ff_r);
    const num_samples = @as(f64, @floatFromInt(nat_aligned.len / 2));

    return .{
        .rms_nat_l = std.math.sqrt(sum_sq_nat_l / num_samples),
        .rms_ff_l = std.math.sqrt(sum_sq_ff_l / num_samples),
        .corr_l = if (denom_l > 1e-15) dot_l / denom_l else 0.0,
        .snr_l = if (err_l > 1e-15) 10.0 * std.math.log10(sum_sq_ff_l / err_l) else 120.0,
        .rms_nat_r = std.math.sqrt(sum_sq_nat_r / num_samples),
        .rms_ff_r = std.math.sqrt(sum_sq_ff_r / num_samples),
        .corr_r = if (denom_r > 1e-15) dot_r / denom_r else 0.0,
        .snr_r = if (err_r > 1e-15) 10.0 * std.math.log10(sum_sq_ff_r / err_r) else 120.0,
    };
}

pub fn printTerminalReport(
    codec_name: []const u8,
    label: []const u8,
    file_path: []const u8,
    overall: SegmentStats,
    segments: []const SegmentStats,
    success_frames: ?usize,
    failed_frames: ?usize,
) void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================================================\n", .{});
    if (success_frames != null and failed_frames != null) {
        std.debug.print("   {s} DECODING COMPARISON REPORT ({s}): Pure Zig Decoder vs FFmpeg Reference\n", .{ codec_name, label });
        std.debug.print("   Input File: {s} | Frames: {d} decoded successfully, {d} failed\n", .{ file_path, success_frames.?, failed_frames.? });
    } else {
        std.debug.print("   {s} DECODING COMPARISON REPORT ({s}): Pure Zig Decoder vs FFmpeg Reference\n", .{ codec_name, label });
        std.debug.print("   Input File: {s}\n", .{file_path});
    }
    std.debug.print("====================================================================================================\n", .{});
    std.debug.print("+-----+---------------+------------+------------+---------------+------------+---------------------+\n", .{});
    std.debug.print("| Seg | Time Window   | Native RMS | FFmpeg RMS | Max Abs Diff  | SNR (dB)   | Waveform Corr (r)   |\n", .{});
    std.debug.print("+-----+---------------+------------+------------+---------------+------------+---------------------+\n", .{});

    for (segments, 0..) |s, idx| {
        std.debug.print("| {d:>3} | {d:>5.2}s..{d:<5.2}s | {d:>10.6} | {d:>10.6} | {d:>13.7} | {d:>8.2}dB | {d:>19.7} |\n", .{
            idx + 1,
            s.start_time,
            s.end_time,
            s.rms_native,
            s.rms_ffmpeg,
            s.max_abs_diff,
            s.snr_db,
            s.correlation,
        });
    }

    std.debug.print("+-----+---------------+------------+------------+---------------+------------+---------------------+\n", .{});
    std.debug.print("| ALL | {d:>5.2}s..{d:<5.2}s | {d:>10.6} | {d:>10.6} | {d:>13.7} | {d:>8.2}dB | {d:>19.7} |\n", .{
        overall.start_time,
        overall.end_time,
        overall.rms_native,
        overall.rms_ffmpeg,
        overall.max_abs_diff,
        overall.snr_db,
        overall.correlation,
    });
    std.debug.print("+-----+---------------+------------+------------+---------------+------------+---------------------+\n", .{});

    // Terminal ASCII correlation sparkline
    std.debug.print("\n[Waveform Correlation Graph across Timeline (Target: > 0.990)]\n", .{});
    for (segments, 0..) |s, idx| {
        const bar_len: usize = if (s.correlation >= 0.99)
            @min(40, @as(usize, @intFromFloat((s.correlation - 0.99) * 4000.0)))
        else
            0;
        var bar: [40]u8 = [_]u8{' '} ** 40;
        @memset(bar[0..bar_len], '#');
        std.debug.print("Seg {d:>2} [{d:>4.1}s]: |{s}| r = {d:.6}\n", .{
            idx + 1,
            s.start_time,
            bar,
            s.correlation,
        });
    }

    // Terminal RMS Comparison Bar
    std.debug.print("\n[RMS Amplitude Comparison: Native Zig [Z] vs FFmpeg Reference [F]]\n", .{});
    for (segments, 0..) |s, idx| {
        const z_len: usize = @min(30, @as(usize, @intFromFloat(s.rms_native * 240.0)));
        const f_len: usize = @min(30, @as(usize, @intFromFloat(s.rms_ffmpeg * 240.0)));
        var z_bar: [30]u8 = [_]u8{' '} ** 30;
        var f_bar: [30]u8 = [_]u8{' '} ** 30;
        @memset(z_bar[0..z_len], '=');
        @memset(f_bar[0..f_len], '=');
        std.debug.print("Seg {d:>2} [{d:>4.1}s]: Zig:[{s}] FFmpeg:[{s}]\n", .{
            idx + 1,
            s.start_time,
            z_bar,
            f_bar,
        });
    }
    std.debug.print("====================================================================================================\n\n", .{});
}

pub const HtmlReportOptions = struct {
    codec_name: []const u8,
    label: []const u8,
    file_path: []const u8,
    out_path: []const u8,
    sample_rate: u32 = 48000,
    scale_native: f32 = 1.0,
    success_frames: ?usize = null,
    failed_frames: ?usize = null,
};

pub fn generateHtmlReport(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: HtmlReportOptions,
    overall: SegmentStats,
    segments: []const SegmentStats,
    native_pcm: []const f32,
    ffmpeg_pcm: []const f32,
) !void {
    _ = allocator;
    const file = try std.Io.Dir.cwd().createFile(io, options.out_path, .{});
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var f_writer = file.writer(io, &file_buf);
    const w = &f_writer.interface;

    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<title>
    );
    try w.writeAll(options.codec_name);
    try w.writeAll(
        \\ Decoding Oscilloscope Comparison</title>
        \\<style>
        \\  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #080d1a; color: #f8fafc; margin: 0; padding: 24px; }
        \\  .container { max-width: 1200px; margin: 0 auto; }
        \\  h1 { font-size: 24px; margin-bottom: 4px; color: #38bdf8; font-weight: 700; }
        \\  .subtitle { color: #94a3b8; margin-bottom: 20px; font-size: 14px; }
        \\  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px; }
        \\  .card { background: #111a2e; border-radius: 10px; padding: 16px 20px; border: 1px solid #1e2e4a; }
        \\  .card-label { font-size: 12px; text-transform: uppercase; color: #94a3b8; font-weight: 600; }
        \\  .card-val { font-size: 24px; font-weight: 700; margin-top: 4px; color: #f1f5f9; }
        \\  .card-val.green { color: #4ade80; }
        \\  .card-val.amber { color: #fbbf24; }
        \\  .chart-box { background: #111a2e; border-radius: 12px; padding: 20px; border: 1px solid #1e2e4a; margin-bottom: 24px; box-shadow: 0 4px 20px rgba(0,0,0,0.4); }
        \\  .toolbar { display: flex; flex-wrap: wrap; gap: 16px; align-items: center; justify-content: space-between; margin-bottom: 16px; padding-bottom: 14px; border-bottom: 1px solid #1e2e4a; }
        \\  .btn-group { display: flex; gap: 4px; background: #0b1120; padding: 3px; border-radius: 8px; border: 1px solid #1e2e4a; }
        \\  .btn { background: transparent; color: #94a3b8; border: none; padding: 6px 12px; border-radius: 6px; font-size: 13px; font-weight: 600; cursor: pointer; transition: all 0.15s; }
        \\  .btn:hover { color: #f1f5f9; background: #1c2842; }
        \\  .btn.active { background: #0284c7; color: #ffffff; }
        \\  .slider-row { display: flex; align-items: center; gap: 12px; flex: 1; min-width: 280px; }
        \\  .slider-row label { font-size: 13px; color: #94a3b8; font-weight: 600; min-width: 60px; }
        \\  input[type=range] { flex: 1; accent-color: #38bdf8; cursor: pointer; }
        \\  .time-badge { font-family: monospace; font-size: 13px; background: #0b1120; padding: 4px 10px; border-radius: 6px; border: 1px solid #1e2e4a; min-width: 55px; text-align: center; color: #38bdf8; }
        \\  canvas { width: 100%; height: 320px; background: #050811; border-radius: 8px; display: block; border: 1px solid #141e33; }
        \\  table { width: 100%; border-collapse: collapse; background: #111a2e; border-radius: 10px; overflow: hidden; border: 1px solid #1e2e4a; margin-top: 8px; }
        \\  th, td { padding: 10px 14px; text-align: right; border-bottom: 1px solid #1e2e4a; font-size: 13px; }
        \\  th:first-child, td:first-child { text-align: left; }
        \\  th { background: #0b1120; color: #94a3b8; font-weight: 600; }
        \\  tr:hover { background: #16223b; }
        \\  .badge { background: #14532d; color: #4ade80; padding: 3px 8px; border-radius: 6px; font-weight: 600; font-size: 11px; }
        \\  .badge.amber { background: #78350f; color: #fde047; }
        \\  .legend { display: flex; gap: 20px; font-size: 13px; align-items: center; }
        \\  .legend-item { display: flex; align-items: center; gap: 8px; }
        \\  .legend-line { width: 22px; height: 3px; border-radius: 2px; }
        \\</style>
        \\</head>
        \\<body>
        \\<div class="container">
    );

    try w.print("  <h1>{s} Waveform Comparison: Pure Zig Decoder vs FFmpeg Reference ({s})</h1>\n", .{ options.codec_name, options.label });
    try w.print("  <div class=\"subtitle\">Input File: <code>{s}</code> ({d} Hz, {s} {s})</div>\n", .{ options.file_path, options.sample_rate, options.codec_name, options.label });

    try w.writeAll(
        \\  <div class="cards">
        \\    <div class="card">
        \\      <div class="card-label">Waveform Correlation</div>
    );

    var corr_buf: [64]u8 = undefined;
    const corr_str = std.fmt.bufPrint(&corr_buf, "{d:.7}", .{overall.correlation}) catch "0.0";
    if (overall.correlation >= 0.90) {
        try w.print("<div class=\"card-val green\">{s} <span class=\"badge\">GOOD</span></div></div>", .{corr_str});
    } else {
        try w.print("<div class=\"card-val amber\">{s} <span class=\"badge amber\">IN PROGRESS</span></div></div>", .{corr_str});
    }

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Signal-to-Noise Ratio</div>
    );
    var snr_buf: [64]u8 = undefined;
    const snr_str = std.fmt.bufPrint(&snr_buf, "{d:.2} dB", .{overall.snr_db}) catch "N/A";
    try w.print("<div class=\"card-val\">{s}</div></div>", .{snr_str});

    if (options.success_frames != null and options.failed_frames != null) {
        try w.writeAll(
            \\    <div class="card">
            \\      <div class="card-label">Frame Decode Health</div>
        );
        var health_buf: [64]u8 = undefined;
        const health_str = std.fmt.bufPrint(&health_buf, "{d} ok / {d} err", .{ options.success_frames.?, options.failed_frames.? }) catch "0";
        try w.print("<div class=\"card-val\">{s}</div></div>", .{health_str});
    }

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Duration & Total Samples</div>
    );
    var dur_buf: [64]u8 = undefined;
    const dur_str = std.fmt.bufPrint(&dur_buf, "{d:.2}s ({d} samples)", .{ overall.end_time, native_pcm.len / 2 }) catch "0s";
    try w.print("<div class=\"card-val\">{s}</div></div></div>", .{dur_str});

    try w.writeAll(
        \\  <div class="chart-box">
        \\    <div class="toolbar">
        \\      <div style="display:flex; gap:12px; align-items:center; flex-wrap:wrap;">
        \\        <div class="btn-group" id="channelBtns">
        \\          <button class="btn active" onclick="setChannel('left')">Left Channel</button>
        \\          <button class="btn" onclick="setChannel('right')">Right Channel</button>
        \\        </div>
        \\        <div class="btn-group" id="modeBtns">
        \\          <button class="btn active" onclick="setMode('split')">Split Tracks (Side-by-Side)</button>
        \\          <button class="btn" onclick="setMode('overlay')">Overlay</button>
        \\          <button class="btn" onclick="setMode('diff')">Difference</button>
        \\        </div>
        \\        <div class="btn-group" id="zoomBtns">
        \\          <button class="btn" onclick="setZoom(100)">100 smp</button>
        \\          <button class="btn active" onclick="setZoom(250)">250 smp</button>
        \\          <button class="btn" onclick="setZoom(500)">500 smp</button>
        \\        </div>
        \\        <div class="btn-group" id="scaleBtns">
        \\          <button class="btn active" id="autoScaleBtn" onclick="toggleAutoScale()">Auto-Fit Amplitude</button>
        \\        </div>
        \\      </div>
        \\      <div class="slider-row">
        \\        <label>Time Window:</label>
        \\        <input type="range" id="timeSlider" min="0" max="9" value="1" oninput="onSlider(this.value)">
        \\        <div class="time-badge" id="timeBadge">1.0s</div>
        \\      </div>
        \\    </div>
        \\
        \\    <div style="display:flex; justify-content:space-between; align-items:center; margin-bottom:12px;">
        \\      <div class="legend" id="legend">
        \\        <div class="legend-item"><div class="legend-line" style="background:#38bdf8;"></div><span>Native Zig
    );
    try w.print(" ({s} Decoder)", .{options.codec_name});
    try w.writeAll(
        \\</span></div>
        \\        <div class="legend-item"><div class="legend-line" style="background:#f43f5e;"></div><span>FFmpeg Reference</span></div>
        \\      </div>
        \\      <div id="graphMetrics" style="font-family:monospace; font-size:12px; color:#94a3b8;"></div>
        \\    </div>
        \\
        \\    <canvas id="scopeCanvas" width="1150" height="320"></canvas>
        \\  </div>
        \\
        \\  <div class="chart-box">
        \\    <div style="font-size:16px; font-weight:600; color:#38bdf8; margin-bottom:12px;">Segment-by-Segment Correlation & RMS Breakdown</div>
        \\    <table>
        \\      <thead>
        \\        <tr>
        \\          <th>Segment</th><th>Time Window</th><th>Native RMS</th><th>FFmpeg RMS</th><th>Max Abs Diff</th><th>SNR</th><th>Correlation (r)</th>
        \\        </tr>
        \\      </thead>
        \\      <tbody>
    );

    for (segments, 0..) |s, idx| {
        try w.print(
            "<tr><td>#{d}</td><td>{d:.2}s - {d:.2}s</td><td>{d:.6}</td><td>{d:.6}</td><td>{d:.6}</td><td>{d:.2} dB</td><td><strong>{d:.7}</strong></td></tr>\n",
            .{ idx + 1, s.start_time, s.end_time, s.rms_native, s.rms_ffmpeg, s.max_abs_diff, s.snr_db, s.correlation },
        );
    }

    try w.writeAll(
        \\      </tbody>
        \\    </table>
        \\  </div>
        \\
        \\<script>
        \\  let currentChannel = 'left';
        \\  let currentMode = 'split';
        \\  let currentZoom = 250;
        \\  let currentTimeIdx = 1;
        \\  let autoScale = true;
        \\
        \\  function toggleAutoScale() {
        \\    autoScale = !autoScale;
        \\    document.getElementById('autoScaleBtn').classList.toggle('active', autoScale);
        \\    drawScope();
        \\  }
        \\
        \\  function setChannel(ch) {
        \\    currentChannel = ch;
        \\    document.querySelectorAll('#channelBtns .btn').forEach(b => b.classList.toggle('active', b.textContent.toLowerCase().includes(ch)));
        \\    drawScope();
        \\  }
        \\
        \\  function setMode(m) {
        \\    currentMode = m;
        \\    document.querySelectorAll('#modeBtns .btn').forEach(b => b.classList.toggle('active', b.textContent.toLowerCase().includes(m)));
        \\    drawScope();
        \\  }
        \\
        \\  function setZoom(z) {
        \\    currentZoom = z;
        \\    document.querySelectorAll('#zoomBtns .btn').forEach(b => b.classList.toggle('active', b.textContent.includes(z)));
        \\    drawScope();
        \\  }
        \\
        \\  function onSlider(v) {
        \\    currentTimeIdx = parseInt(v);
        \\    document.getElementById('timeBadge').textContent = (currentTimeIdx * 1.0).toFixed(1) + 's';
        \\    drawScope();
        \\  }
        \\
        \\  function drawScope() {
        \\    const canvas = document.getElementById('scopeCanvas');
        \\    const ctx = canvas.getContext('2d');
        \\    const W = canvas.width;
        \\    const H = canvas.height;
        \\    ctx.clearRect(0, 0, W, H);
        \\
        \\    ctx.strokeStyle = '#141e33';
        \\    ctx.lineWidth = 1;
        \\    ctx.beginPath();
        \\    for (let x = 0; x < W; x += 50) { ctx.moveTo(x, 0); ctx.lineTo(x, H); }
        \\    for (let y = 0; y < H; y += 40) { ctx.moveTo(0, y); ctx.lineTo(W, y); }
        \\    ctx.stroke();
        \\
        \\    const win = windows[currentTimeIdx] || windows[0];
        \\    const nat = (currentChannel === 'left') ? win.natL : win.natR;
        \\    const ff  = (currentChannel === 'left') ? win.ffL  : win.ffR;
        \\
        \\    const samplesCount = Math.min(currentZoom, nat.length, ff.length);
        \\    const step = W / (samplesCount - 1);
        \\
        \\    let maxNat = 0, maxFf = 0;
        \\    for (let i = 0; i < samplesCount; i++) {
        \\      if (Math.abs(nat[i]) > maxNat) maxNat = Math.abs(nat[i]);
        \\      if (Math.abs(ff[i]) > maxFf) maxFf = Math.abs(ff[i]);
        \\    }
        \\    const scaleNat = (autoScale && maxNat > 0.0001) ? (0.8 / maxNat) : 1.0;
        \\    const scaleFf  = (autoScale && maxFf  > 0.0001) ? (0.8 / maxFf)  : 1.0;
        \\
        \\    if (currentMode === 'split') {
        \\      const midH = H / 2;
        \\      ctx.strokeStyle = '#1e293b';
        \\      ctx.lineWidth = 1.5;
        \\      ctx.beginPath();
        \\      ctx.moveTo(0, midH * 0.5); ctx.lineTo(W, midH * 0.5);
        \\      ctx.moveTo(0, midH * 1.5); ctx.lineTo(W, midH * 1.5);
        \\      ctx.stroke();
        \\
        \\      ctx.strokeStyle = '#38bdf8';
        \\      ctx.lineWidth = 2;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < samplesCount; i++) {
        \\        const x = i * step;
        \\        const rawY = (midH * 0.5) - (nat[i] * scaleNat * midH * 0.42);
        \\        const y = Math.max(2, Math.min(midH - 2, rawY));
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\
        \\      ctx.strokeStyle = '#f43f5e';
        \\      ctx.lineWidth = 2;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < samplesCount; i++) {
        \\        const x = i * step;
        \\        const rawY = (midH * 1.5) - (ff[i] * scaleFf * midH * 0.42);
        \\        const y = Math.max(midH + 2, Math.min(H - 2, rawY));
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\
        \\      ctx.font = '11px monospace';
        \\      ctx.fillStyle = '#38bdf8';
        \\      ctx.fillText(`NATIVE ZIG (TOP, Peak: ${maxNat.toFixed(2)})`, 12, 20);
        \\      ctx.fillStyle = '#f43f5e';
        \\      ctx.fillText(`FFMPEG REFERENCE (BOTTOM, Peak: ${maxFf.toFixed(4)})`, 12, midH + 20);
        \\    } else if (currentMode === 'overlay') {
        \\      const midY = H / 2;
        \\      ctx.strokeStyle = '#1e293b';
        \\      ctx.lineWidth = 1.5;
        \\      ctx.beginPath();
        \\      ctx.moveTo(0, midY); ctx.lineTo(W, midY);
        \\      ctx.stroke();
        \\
        \\      ctx.strokeStyle = '#f43f5e';
        \\      ctx.lineWidth = 2.5;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < samplesCount; i++) {
        \\        const x = i * step;
        \\        const rawY = midY - (ff[i] * scaleFf * midY * 0.85);
        \\        const y = Math.max(2, Math.min(H - 2, rawY));
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\
        \\      ctx.strokeStyle = '#38bdf8';
        \\      ctx.lineWidth = 1.8;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < samplesCount; i++) {
        \\        const x = i * step;
        \\        const rawY = midY - (nat[i] * scaleNat * midY * 0.85);
        \\        const y = Math.max(2, Math.min(H - 2, rawY));
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\    } else if (currentMode === 'diff') {
        \\      const midY = H / 2;
        \\      ctx.strokeStyle = '#1e293b';
        \\      ctx.lineWidth = 1.5;
        \\      ctx.beginPath();
        \\      ctx.moveTo(0, midY); ctx.lineTo(W, midY);
        \\      ctx.stroke();
        \\
        \\      ctx.strokeStyle = '#fbbf24';
        \\      ctx.lineWidth = 2;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < samplesCount; i++) {
        \\        const diff = (nat[i] * scaleNat) - (ff[i] * scaleFf);
        \\        const x = i * step;
        \\        const rawY = midY - (diff * midY * 0.85);
        \\        const y = Math.max(2, Math.min(H - 2, rawY));
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\    }
        \\
        \\    let dot = 0, sNat = 0, sFf = 0;
        \\    for (let i = 0; i < samplesCount; i++) {
        \\      dot += nat[i] * ff[i];
        \\      sNat += nat[i] * nat[i];
        \\      sFf  += ff[i] * ff[i];
        \\    }
        \\    const denom = Math.sqrt(sNat * sFf);
        \\    const localR = denom > 1e-12 ? (dot / denom).toFixed(6) : '0.000000';
        \\    document.getElementById('graphMetrics').textContent =
        \\      `Peak Nat: ${maxNat.toFixed(2)} | Peak FF: ${maxFf.toFixed(4)} | Auto-Fit: ${autoScale ? 'ON' : 'OFF'} | Window r=${localR}`;
        \\  }
        \\
        \\  const windows = [
    );

    // Write 10 inspection windows of 500 samples each
    const sr = options.sample_rate;
    for (0..10) |w_idx| {
        const start_sample = w_idx * sr;
        const total_smp = native_pcm.len / 2;
        const actual_count = @min(500, if (start_sample < total_smp) total_smp - start_sample else 0);

        try w.writeAll("    { natL: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2;
            var pbuf: [32]u8 = undefined;
            const val = native_pcm[idx] * options.scale_native;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{val}) catch "0,";
            try w.writeAll(pstr);
        }
        try w.writeAll("], natR: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2 + 1;
            var pbuf: [32]u8 = undefined;
            const val = native_pcm[idx] * options.scale_native;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{val}) catch "0,";
            try w.writeAll(pstr);
        }
        try w.writeAll("], ffL: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2;
            var pbuf: [32]u8 = undefined;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{ffmpeg_pcm[idx]}) catch "0,";
            try w.writeAll(pstr);
        }
        try w.writeAll("], ffR: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2 + 1;
            var pbuf: [32]u8 = undefined;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{ffmpeg_pcm[idx]}) catch "0,";
            try w.writeAll(pstr);
        }
        try w.writeAll("] },\n");
    }

    try w.writeAll(
        \\  ];
        \\
        \\  drawScope();
        \\</script>
        \\</div></body></html>
    );

    try f_writer.flush();
}
