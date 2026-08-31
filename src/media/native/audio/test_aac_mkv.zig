const std = @import("std");
const track_parser = @import("../mkv/track_parser.zig");
const types = @import("../mkv/types.zig");
const block_reader = @import("../mkv/block_reader.zig");
const aac_dec = @import("aac_dec.zig");
const c = @import("../../../core/c.zig").c;

const SegmentStats = struct {
    start_time: f64,
    end_time: f64,
    sample_count: usize,
    rms_native: f64,
    rms_ffmpeg: f64,
    max_abs_diff: f32,
    snr_db: f64,
    correlation: f64,
};

fn calculateStats(native: []const f32, ffmpeg: []const f32, sample_rate: u32, num_segments: usize, allocator: std.mem.Allocator) ![]SegmentStats {
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

        for (nat_slice, ff_slice) |n, f| {
            sum_sq_nat += @as(f64, n) * @as(f64, n);
            sum_sq_ff += @as(f64, f) * @as(f64, f);
            const err = @as(f64, n) - @as(f64, f);
            sum_sq_err += err * err;
            dot += @as(f64, n) * @as(f64, f);
            const diff = @abs(n - f);
            if (diff > max_diff) max_diff = diff;
        }

        const denom_corr = std.math.sqrt(sum_sq_nat * sum_sq_ff);
        const corr = if (denom_corr > 1e-15) dot / denom_corr else 0.0;
        const snr = if (sum_sq_err > 1e-15) 10.0 * std.math.log10(sum_sq_ff / sum_sq_err) else 120.0;

        try stats_list.append(allocator, .{
            .start_time = @as(f64, @floatFromInt(start_sample)) / @as(f64, @floatFromInt(sample_rate)),
            .end_time = @as(f64, @floatFromInt(end_sample)) / @as(f64, @floatFromInt(sample_rate)),
            .sample_count = count,
            .rms_native = std.math.sqrt(sum_sq_nat / @as(f64, @floatFromInt(nat_slice.len))),
            .rms_ffmpeg = std.math.sqrt(sum_sq_ff / @as(f64, @floatFromInt(ff_slice.len))),
            .max_abs_diff = max_diff,
            .snr_db = snr,
            .correlation = corr,
        });
    }

    return try stats_list.toOwnedSlice(allocator);
}

fn printTerminalReport(label: []const u8, file_path: []const u8, overall: SegmentStats, segments: []const SegmentStats, success_frames: usize, failed_frames: usize) void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================================================\n", .{});
    std.debug.print("   AAC DECODING COMPARISON REPORT ({s}): Pure Zig AacDecoder vs FFmpeg Reference\n", .{label});
    std.debug.print("   Input File: {s} | Frames: {d} decoded successfully, {d} failed\n", .{ file_path, success_frames, failed_frames });
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
    std.debug.print("\n[Waveform Correlation Graph across Timeline]\n", .{});
    for (segments, 0..) |s, idx| {
        const bar_len: usize = if (s.correlation > 0.0)
            @min(40, @as(usize, @intFromFloat(s.correlation * 40.0)))
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
        @memset(z_bar[0..z_len], '=');
        var f_bar: [30]u8 = [_]u8{' '} ** 30;
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

fn generateHtmlReport(
    io: std.Io,
    allocator: std.mem.Allocator,
    out_path: []const u8,
    label: []const u8,
    file_path: []const u8,
    overall: SegmentStats,
    segments: []const SegmentStats,
    native_pcm: []const f32,
    ffmpeg_pcm: []const f32,
    success_frames: usize,
    failed_frames: usize,
) !void {
    _ = allocator;
    const file = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer file.close(io);

    var file_buf: [65536]u8 = undefined;
    var f_writer = file.writer(io, &file_buf);
    const w = &f_writer.interface;

    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<title>AAC Decoding Oscilloscope Comparison</title>
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

    try w.writeAll("  <h1>AAC Waveform Comparison: Pure Zig AacDecoder vs FFmpeg Reference (");
    try w.writeAll(label);
    try w.writeAll(")</h1>\n");
    try w.writeAll("  <div class=\"subtitle\">Input File: <code>");
    try w.writeAll(file_path);
    try w.writeAll("</code> (48,000 Hz, AAC ");
    try w.writeAll(label);
    try w.writeAll(")</div>\n");

    try w.writeAll(
        \\  <div class="cards">
        \\    <div class="card">
        \\      <div class="card-label">Waveform Correlation</div>
    );

    var corr_buf: [64]u8 = undefined;
    const corr_str = std.fmt.bufPrint(&corr_buf, "{d:.7}", .{overall.correlation}) catch "0.0";
    if (overall.correlation >= 0.90) {
        try w.writeAll("<div class=\"card-val green\">");
        try w.writeAll(corr_str);
        try w.writeAll(" <span class=\"badge\">GOOD</span></div></div>");
    } else {
        try w.writeAll("<div class=\"card-val amber\">");
        try w.writeAll(corr_str);
        try w.writeAll(" <span class=\"badge amber\">BROKEN / IN PROGRESS</span></div></div>");
    }

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Signal-to-Noise Ratio</div>
    );
    var snr_buf: [64]u8 = undefined;
    const snr_str = std.fmt.bufPrint(&snr_buf, "{d:.2} dB", .{overall.snr_db}) catch "N/A";
    try w.writeAll("<div class=\"card-val\">");
    try w.writeAll(snr_str);
    try w.writeAll("</div></div>");

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Frame Decode Health</div>
    );
    var health_buf: [64]u8 = undefined;
    const health_str = std.fmt.bufPrint(&health_buf, "{d} ok / {d} err", .{ success_frames, failed_frames }) catch "0";
    try w.writeAll("<div class=\"card-val\">");
    try w.writeAll(health_str);
    try w.writeAll("</div></div>");

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Duration & Total Samples</div>
    );
    var dur_buf: [64]u8 = undefined;
    const dur_str = std.fmt.bufPrint(&dur_buf, "{d:.2}s ({d} samples)", .{ overall.end_time, native_pcm.len / 2 }) catch "0s";
    try w.writeAll("<div class=\"card-val\">");
    try w.writeAll(dur_str);
    try w.writeAll("</div></div></div>");

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
        \\        <div class="legend-item"><div class="legend-line" style="background:#38bdf8;"></div><span>Native Zig (AacDecoder)</span></div>
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
        var row_buf: [256]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buf,
            \\<tr><td>#{d}</td><td>{d:.2}s - {d:.2}s</td><td>{d:.6}</td><td>{d:.6}</td><td>{d:.6}</td><td>{d:.2} dB</td><td><strong>{d:.7}</strong></td></tr>
        , .{ idx + 1, s.start_time, s.end_time, s.rms_native, s.rms_ffmpeg, s.max_abs_diff, s.snr_db, s.correlation });
        try w.writeAll(row);
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
    const sample_rate: usize = 48000;
    for (0..10) |w_idx| {
        const start_sample = w_idx * sample_rate;
        const total_smp = native_pcm.len / 2;
        const actual_count = @min(500, if (start_sample < total_smp) total_smp - start_sample else 0);

        try w.writeAll("    { natL: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2;
            var pbuf: [32]u8 = undefined;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{native_pcm[idx]}) catch "0,";
            try w.writeAll(pstr);
        }
        try w.writeAll("], natR: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2 + 1;
            var pbuf: [32]u8 = undefined;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{native_pcm[idx]}) catch "0,";
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

pub fn runAacTest(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    label: []const u8,
    report_filename: []const u8,
    expected_channels: usize,
) !void {
    const testing = std.testing;

    // 1. Demux MKV natively to find the AAC audio track
    const tracks = try track_parser.parseMkvTracks(allocator, io, file_path);
    defer {
        for (tracks) |*t| t.deinit(allocator);
        allocator.free(tracks);
    }

    var audio_track_opt: ?types.MkvTrackInfo = null;
    for (tracks) |t| {
        if (t.track_type == .Audio) {
            audio_track_opt = t;
            break;
        }
    }
    try testing.expect(audio_track_opt != null);
    const audio_track = audio_track_opt.?;
    try testing.expectEqualStrings("A_AAC", audio_track.codec_id);
    try testing.expectEqual(expected_channels, audio_track.channels);
    if (audio_track.codec_private) |cp| {
        std.debug.print("\n=== AUDIO TRACK CODEC_PRIVATE (len={d}): {x} ===\n", .{ cp.len, cp });
    } else {
        std.debug.print("\n=== AUDIO TRACK CODEC_PRIVATE IS NULL ===\n", .{});
    }

    // 2. Demux and decode all AAC frames using pure Zig AacDecoder
    const demux_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var decoder = aac_dec.AacDecoder.init();
    decoder.sample_rate = audio_track.sample_rate;
    decoder.channels = audio_track.channels;

    var native_pcm = std.ArrayList(f32).empty;
    defer native_pcm.deinit(allocator);

    var nat_6ch: [6]std.ArrayList(f32) = undefined;
    var ff_6ch: [6]std.ArrayList(f32) = undefined;
    for (0..6) |ch| {
        nat_6ch[ch] = std.ArrayList(f32).empty;
        ff_6ch[ch] = std.ArrayList(f32).empty;
    }
    defer {
        for (0..6) |ch| {
            nat_6ch[ch].deinit(allocator);
            ff_6ch[ch].deinit(allocator);
        }
    }

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var current_file_pos: u64 = 0;
    var success_frames: usize = 0;
    var failed_frames: usize = 0;
    var frame_pcm: [2048]f32 = undefined;
    var first_err: ?anyerror = null;

    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            if (success_frames + failed_frames < 5) {
                std.debug.print("[BLOCK INFO #{d}] offset={d} size={d} pts={d}\n", .{
                    success_frames + failed_frames, blk.payload_offset, blk.payload_size, blk.pts_ms,
                });
            }
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            if (decoder.decodeFrame(raw_pkt_buf.items, &frame_pcm)) |n_samples| {
                try native_pcm.appendSlice(allocator, frame_pcm[0 .. n_samples * 2]);
                for (0..6) |ch| {
                    for (decoder.last_ch_pcm[ch]) |v| {
                        try nat_6ch[ch].append(allocator, v * (1.0 / 65536.0));
                    }
                }
                if (success_frames < 10) {
                    var max_f: f32 = 0.0;
                    var sq_sum: f64 = 0.0;
                    for (frame_pcm[0 .. n_samples * 2]) |s| {
                        if (@abs(s) > max_f) max_f = @abs(s);
                        sq_sum += @as(f64, s) * @as(f64, s);
                    }
                    const frame_rms = std.math.sqrt(sq_sum / @as(f64, @floatFromInt(n_samples * 2)));
                    std.debug.print("[AAC FRAME {d:>2}] max={d:.6} rms={d:.6} len={d}\n", .{ success_frames, max_f, frame_rms, raw_pkt_buf.items.len });
                }
                success_frames += 1;
            } else |err| {
                const total_f = success_frames + failed_frames;
                if (failed_frames < 5) {
                    std.debug.print("[AAC FAIL FRAME #{d}]: {}\n", .{ total_f, err });
                }
                if (first_err == null) first_err = err;
                failed_frames += 1;
                // Pad with zeros to maintain time synchronization with reference
                const zero_pcm = [_]f32{0.0} ** 2048;
                try native_pcm.appendSlice(allocator, &zero_pcm);
            }
        }
    }

    if (first_err) |err| {
        std.debug.print("[AAC Decoder Notice] Frame decode encountered error: {} (Failed frames: {d}/{d})\n", .{ err, failed_frames, success_frames + failed_frames });
    }

    // 3. Decode the same file with FFmpeg libavcodec for reference
    var in_fmt_ctx: ?*c.AVFormatContext = null;
    const c_file_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file_path);

    c.av_log_set_level(c.AV_LOG_TRACE);
    if (c.avformat_open_input(&in_fmt_ctx, c_file_path.ptr, null, null) < 0) return error.OpenInputFailed;
    defer c.avformat_close_input(&in_fmt_ctx);

    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.FindStreamInfoFailed;

    var ff_audio_stream_idx: ?usize = null;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            ff_audio_stream_idx = i;
            break;
        }
    }
    try testing.expect(ff_audio_stream_idx != null);
    const audio_stream = in_fmt_ctx.?.streams[ff_audio_stream_idx.?];

    const codec = c.avcodec_find_decoder(audio_stream.*.codecpar.*.codec_id) orelse return error.DecoderNotFound;
    var codec_ctx = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&codec_ctx);

    if (c.avcodec_parameters_to_context(codec_ctx, audio_stream.*.codecpar) < 0) return error.ParametersToContextFailed;

    codec_ctx.*.debug |= c.FF_DEBUG_STARTCODE;
    c.av_log_set_level(c.AV_LOG_DEBUG);

    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.OpenCodecFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&pkt);

    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);

    var ffmpeg_pcm = std.ArrayList(f32).empty;
    defer ffmpeg_pcm.deinit(allocator);

    const LEVEL_3DB: f32 = 0.7071067811865475;
    const NORM_51: f32 = 1.0 / (1.0 + 2.0 * LEVEL_3DB);

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == @as(c_int, @intCast(ff_audio_stream_idx.?))) {
            if (ffmpeg_pcm.items.len < 10240) {
                std.debug.print("[FFMPEG PKT] size={d} pts={d}\n", .{ pkt.*.size, pkt.*.pts });
            }
            if (c.avcodec_send_packet(codec_ctx, pkt) < 0) return error.SendPacketFailed;
            while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
                const nb_samples: usize = @intCast(frame.*.nb_samples);
                const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));
                const ch_count = if (@hasDecl(c, "AVChannelLayout")) frame.*.ch_layout.nb_channels else frame.*.channels;
                if (ffmpeg_pcm.items.len < 10240) {
                    var rms_ch: [6]f32 = [_]f32{0.0} ** 6;
                    for (0..6) |ch| {
                        var sum_sq: f64 = 0;
                        for (0..nb_samples) |s| {
                            const val: f64 = data[ch][s];
                            sum_sq += val * val;
                        }
                        rms_ch[ch] = @floatCast(@sqrt(sum_sq / @as(f64, @floatFromInt(nb_samples))));
                    }
                    std.debug.print("[FFMPEG FRAME pts={d}] C={d:.4} L={d:.4} R={d:.4} LFE={d:.4} Ls={d:.4} Rs={d:.4}\n", .{
                        frame.*.pts, rms_ch[2], rms_ch[0], rms_ch[1], rms_ch[3], rms_ch[4], rms_ch[5],
                    });
                    const c_data = data[2];
                    var peak_idx: usize = 0;
                    var peak_val: f32 = 0;
                    for (0..nb_samples) |idx| {
                        if (@abs(c_data[idx]) > @abs(peak_val)) {
                            peak_val = c_data[idx];
                            peak_idx = idx;
                        }
                    }
                    std.debug.print("  [FFMPEG FRAME pts={d} C PEAK] peak_val={d:.5} at sample={d}\n", .{
                        frame.*.pts, peak_val, peak_idx,
                    });
                    std.debug.print("  [FFMPEG FRAME pts={d} C SAMPLES 0..15]:\n    ", .{frame.*.pts});
                    for (0..16) |s| std.debug.print("{d:.5} ", .{c_data[s]});
                    std.debug.print("\n", .{});
                }

                if (ch_count >= 6) {
                    // 5.1 Surround downmix to stereo (matching ITU-R BS.775 / AacDecoder downmix)
                    const l = data[0];
                    const r = data[1];
                    const center = data[2];
                    const ls = data[4];
                    const rs = data[5];
                    for (0..nb_samples) |s| {
                        for (0..6) |ch| {
                            try ff_6ch[ch].append(allocator, data[ch][s]);
                        }
                        try ffmpeg_pcm.append(allocator, (l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB) * NORM_51);
                        try ffmpeg_pcm.append(allocator, (r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB) * NORM_51);
                    }
                } else {
                    // 2.0 Stereo
                    const ch0 = data[0];
                    const ch1 = data[1];
                    for (0..nb_samples) |s| {
                        try ffmpeg_pcm.append(allocator, ch0[s]);
                        try ffmpeg_pcm.append(allocator, ch1[s]);
                    }
                }
            }
        }
    }

    _ = c.avcodec_send_packet(codec_ctx, null);
    while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
        const nb_samples: usize = @intCast(frame.*.nb_samples);
        const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));
        const ch_count = if (@hasDecl(c, "AVChannelLayout")) frame.*.ch_layout.nb_channels else frame.*.channels;

        if (ch_count >= 6) {
            const l = data[0];
            const r = data[1];
            const center = data[2];
            const lfe = data[3];
            const ls = data[4];
            const rs = data[5];
            if (ffmpeg_pcm.items.len == 0) {
                var rms: [6]f64 = [_]f64{0.0} ** 6;
                for (0..nb_samples) |s| {
                    rms[0] += @as(f64, l[s]) * @as(f64, l[s]);
                    rms[1] += @as(f64, r[s]) * @as(f64, r[s]);
                    rms[2] += @as(f64, center[s]) * @as(f64, center[s]);
                    rms[3] += @as(f64, lfe[s]) * @as(f64, lfe[s]);
                    rms[4] += @as(f64, ls[s]) * @as(f64, ls[s]);
                    rms[5] += @as(f64, rs[s]) * @as(f64, rs[s]);
                }
                for (0..6) |ch| rms[ch] = @sqrt(rms[ch] / @as(f64, @floatFromInt(nb_samples)));
                std.debug.print("  [FFMPEG F0 CH RMS] L={d:.4} R={d:.4} C={d:.4} LFE={d:.4} Ls={d:.4} Rs={d:.4}\n", .{
                    rms[0], rms[1], rms[2], rms[3], rms[4], rms[5],
                });
            }
            for (0..nb_samples) |s| {
                for (0..6) |ch| {
                    try ff_6ch[ch].append(allocator, data[ch][s]);
                }
                try ffmpeg_pcm.append(allocator, (l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB) * NORM_51);
                try ffmpeg_pcm.append(allocator, (r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB) * NORM_51);
            }
        } else {
            const ch0 = data[0];
            const ch1 = data[1];
            for (0..nb_samples) |s| {
                try ffmpeg_pcm.append(allocator, ch0[s]);
                try ffmpeg_pcm.append(allocator, ch1[s]);
            }
        }
    }

    // If FFmpeg skipped priming frames due to container side data, native will have 1 extra frame (2048 floats)
    const nat_lead = if (native_pcm.items.len > ffmpeg_pcm.items.len) native_pcm.items.len - ffmpeg_pcm.items.len else 0;
    const native_aligned = native_pcm.items[nat_lead..];
    const ffmpeg_aligned = ffmpeg_pcm.items;
    const compare_len = @min(native_aligned.len, ffmpeg_aligned.len);
    std.debug.print("ALIGNED LENGTHS: native={d} ffmpeg={d} compare={d} (nat_lead={d})\n", .{ native_aligned.len, ffmpeg_aligned.len, compare_len, nat_lead });
    const nat_aligned = native_aligned[0..compare_len];
    const ff_aligned = ffmpeg_aligned[0..compare_len];

    // Find best lag cross-correlation to verify time alignment
    var best_lag: i32 = 0;
    var max_abs_r: f64 = 0.0;
    var best_r: f64 = 0.0;
    const test_n: usize = 48000 * 2; // test first 1 second of stereo
    if (nat_aligned.len >= test_n + 8192 and ff_aligned.len >= test_n + 8192) {
        var lag: i32 = -4096;
        while (lag <= 4096) : (lag += 1) {
            var sum_prod: f64 = 0;
            var sum_nat_sq: f64 = 0;
            var sum_ff_sq: f64 = 0;
            for (0..test_n) |idx| {
                const nat_idx: usize = @intCast(@as(i64, @intCast(idx + 4096)) + lag);
                const ff_idx: usize = idx + 4096;
                const n_val = nat_aligned[nat_idx];
                const f_val = ff_aligned[ff_idx];
                sum_prod += @as(f64, n_val) * @as(f64, f_val);
                sum_nat_sq += @as(f64, n_val) * @as(f64, n_val);
                sum_ff_sq += @as(f64, f_val) * @as(f64, f_val);
            }
            if (sum_nat_sq > 0 and sum_ff_sq > 0) {
                const curr_r = sum_prod / @sqrt(sum_nat_sq * sum_ff_sq);
                if (@abs(curr_r) > max_abs_r) {
                    max_abs_r = @abs(curr_r);
                    best_r = curr_r;
                    best_lag = lag;
                }
            }
        }
        std.debug.print("  [LAG SEARCH] Best lag={d} r={d:.6}\n", .{ best_lag, best_r });
    }

    // Read tmp/ref.raw directly for independent verification
    if (std.Io.Dir.cwd().openFile(io, "tmp/ref.raw", .{ .mode = .read_only })) |ref_file| {
        var r_file = ref_file;
        defer r_file.close(io);
        const ref_bytes = try allocator.alloc(u8, 6 * 4 * 48000);
        defer allocator.free(ref_bytes);
        var r_buf: [1024]u8 = undefined;
        var r_rdr = r_file.reader(io, &r_buf);
        const n_read = r_rdr.interface.readSliceShort(ref_bytes) catch 0;
        const ref_floats = std.mem.bytesAsSlice(f32, ref_bytes[0..n_read]);
        std.debug.print("  [REF.RAW C SAMPLES 0..15]:\n    ", .{});
        for (0..16) |s| std.debug.print("{d:.5} ", .{ref_floats[s * 6 + 2]});
        std.debug.print("\n", .{});
        std.debug.print("  [NAT F0 C SAMPLES 0..15]:\n    ", .{});
        for (0..16) |s| std.debug.print("{d:.5} ", .{nat_6ch[2].items[s]});
        std.debug.print("\n", .{});
        std.debug.print("  [NAT F1 C SAMPLES 0..15]:\n    ", .{});
        for (0..16) |s| std.debug.print("{d:.5} ", .{nat_6ch[2].items[1024 + s]});
        std.debug.print("\n", .{});
        // Find best match for ref_floats[0..64] across nat_6ch[2].items[0..4096]
        var min_err: f64 = 1e9;
        var min_off: usize = 0;
        for (0..3000) |test_off| {
            var err: f64 = 0;
            for (0..64) |s| {
                const diff = nat_6ch[2].items[test_off + s] - ref_floats[s * 6 + 2];
                err += @as(f64, diff) * @as(f64, diff);
            }
            if (err < min_err) {
                min_err = err;
                min_off = test_off;
            }
        }
        std.debug.print("  [EXACT MATCH SEARCH]: min_off={d} err={d:.6}\n", .{ min_off, min_err });
        std.debug.print("  [AT MIN_OFF]:\n    ", .{});
        for (0..16) |s| std.debug.print("{d:.5} ", .{nat_6ch[2].items[min_off + s]});
        std.debug.print("\n", .{});

        std.debug.print("=== 6-CHANNEL DIRECT COMPARISON (Native vs FFmpeg, 48k samples) ===\n", .{});
        const ch_names = [_][]const u8{ "FL (0)", "FR (1)", "FC (2)", "LFE(3)", "BL (4)", "BR (5)" };
        for (0..6) |ch| {
            if (nat_6ch[ch].items.len >= 49024 and ff_6ch[ch].items.len >= 48000) {
                var best_lag_ch: i32 = 0;
                var max_r_ch: f64 = 0.0;
                var best_signed_r_ch: f64 = 0.0;
                const N_TEST: usize = 40000;

                var lag: i32 = -200;
                while (lag <= 200) : (lag += 1) {
                    var sum_prod: f64 = 0;
                    var sum_n_sq: f64 = 0;
                    var sum_f_sq: f64 = 0;
                    for (0..N_TEST) |s| {
                        const n_idx: usize = @intCast(@as(i64, @intCast(1024 + 1000 + s)) + lag);
                        const f_idx: usize = 1000 + s;
                        const nv = nat_6ch[ch].items[n_idx];
                        const fv = ff_6ch[ch].items[f_idx];
                        sum_prod += @as(f64, nv) * @as(f64, fv);
                        sum_n_sq += @as(f64, nv) * @as(f64, nv);
                        sum_f_sq += @as(f64, fv) * @as(f64, fv);
                    }
                    if (sum_n_sq > 0 and sum_f_sq > 0) {
                        const curr_r = sum_prod / @sqrt(sum_n_sq * sum_f_sq);
                        if (@abs(curr_r) > max_r_ch) {
                            max_r_ch = @abs(curr_r);
                            best_signed_r_ch = curr_r;
                            best_lag_ch = lag;
                        }
                    }
                }
                std.debug.print("  [{s}] Best lag={d:>4} Corr r={d:.6}\n", .{
                    ch_names[ch], best_lag_ch, best_signed_r_ch,
                });
            }
        }

        std.debug.print("  [LFE PERIOD AND PEAKS]:\n", .{});
        const nat_lfe = nat_6ch[3].items[1024..];
        const ff_lfe = ff_6ch[3].items;
        std.debug.print("    Native LFE peaks at: ", .{});
        var nat_pk_count: usize = 0;
        for (1..3999) |s| {
            if (nat_lfe[s] > 0.03 and nat_lfe[s] >= nat_lfe[s - 1] and nat_lfe[s] >= nat_lfe[s + 1]) {
                std.debug.print("{d} (val={d:.4}) ", .{ s, nat_lfe[s] });
                nat_pk_count += 1;
                if (nat_pk_count >= 5) break;
            }
        }
        std.debug.print("\n    FFmpeg LFE peaks at: ", .{});
        var ff_pk_count: usize = 0;
        for (1..3999) |s| {
            if (ff_lfe[s] > 0.03 and ff_lfe[s] >= ff_lfe[s - 1] and ff_lfe[s] >= ff_lfe[s + 1]) {
                std.debug.print("{d} (val={d:.4}) ", .{ s, ff_lfe[s] });
                ff_pk_count += 1;
                if (ff_pk_count >= 5) break;
            }
        }
        std.debug.print("\n", .{});
        for (1..11) |f_idx| {
            const nat_start = f_idx * 1024;
            const ref_center_s = (f_idx - 1) * 1024;
            const search_start = if (ref_center_s >= 200) ref_center_s - 200 else 0;
            const search_end = ref_center_s + 200;
            var max_r: f64 = 0.0;
            var best_off: usize = 0;
            var best_signed_r: f64 = 0.0;

            for (search_start..search_end) |off| {
                if (off + 1024 > ref_floats.len / 6) break;
                var sum_prod: f64 = 0;
                var sum_n_sq: f64 = 0;
                var sum_r_sq: f64 = 0;
                for (0..1024) |s| {
                    const n_val = nat_6ch[2].items[nat_start + s];
                    const r_val = ref_floats[(off + s) * 6 + 2];
                    sum_prod += @as(f64, n_val) * @as(f64, r_val);
                    sum_n_sq += @as(f64, n_val) * @as(f64, n_val);
                    sum_r_sq += @as(f64, r_val) * @as(f64, r_val);
                }
                if (sum_n_sq > 0 and sum_r_sq > 0) {
                    const r_corr = sum_prod / @sqrt(sum_n_sq * sum_r_sq);
                    if (@abs(r_corr) > max_r) {
                        max_r = @abs(r_corr);
                        best_signed_r = r_corr;
                        best_off = off;
                    }
                }
            }
            const expected_off = (f_idx - 1) * 1024;
            const diff: i64 = @as(i64, @intCast(best_off)) - @as(i64, @intCast(expected_off));
            std.debug.print("  [Frame {d:>2}] best_off={d:>5} (expected {d:>5}, diff={d:>3}) r={d:.6}\n", .{
                f_idx, best_off, expected_off, diff, best_signed_r,
            });
        }
    } else |_| {}

    std.debug.print("  NAT ALIGNED[0..10]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
        nat_aligned[0], nat_aligned[1], nat_aligned[2], nat_aligned[3],
        nat_aligned[4], nat_aligned[5], nat_aligned[6], nat_aligned[7],
    });
    std.debug.print("  FF  ALIGNED[0..10]: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{
        ff_aligned[0], ff_aligned[1], ff_aligned[2], ff_aligned[3],
        ff_aligned[4], ff_aligned[5], ff_aligned[6], ff_aligned[7],
    });

    const NUM_SEGMENTS = 10;
    const segment_stats = try calculateStats(nat_aligned, ff_aligned, 48000, NUM_SEGMENTS, allocator);
    defer allocator.free(segment_stats);

    var sum_sq_nat_all: f64 = 0.0;
    var sum_sq_ff_all: f64 = 0.0;
    var sum_sq_err_all: f64 = 0.0;
    var dot_all: f64 = 0.0;
    var max_diff_all: f32 = 0.0;

    var sum_sq_nat_l: f64 = 0.0;
    var sum_sq_ff_l: f64 = 0.0;
    var err_l: f64 = 0.0;
    var dot_l: f64 = 0.0;

    var sum_sq_nat_r: f64 = 0.0;
    var sum_sq_ff_r: f64 = 0.0;
    var err_r: f64 = 0.0;
    var dot_r: f64 = 0.0;

    for (0..nat_aligned.len / 2) |s| {
        const nl = nat_aligned[s * 2 + 0];
        const nr = nat_aligned[s * 2 + 1];
        const fl = ff_aligned[s * 2 + 0];
        const fr = ff_aligned[s * 2 + 1];

        sum_sq_nat_all += @as(f64, nl) * @as(f64, nl) + @as(f64, nr) * @as(f64, nr);
        sum_sq_ff_all += @as(f64, fl) * @as(f64, fl) + @as(f64, fr) * @as(f64, fr);
        const el = @as(f64, nl) - @as(f64, fl);
        const er = @as(f64, nr) - @as(f64, fr);
        sum_sq_err_all += el * el + er * er;
        dot_all += @as(f64, nl) * @as(f64, fl) + @as(f64, nr) * @as(f64, fr);

        sum_sq_nat_l += @as(f64, nl) * @as(f64, nl);
        sum_sq_ff_l += @as(f64, fl) * @as(f64, fl);
        err_l += el * el;
        dot_l += @as(f64, nl) * @as(f64, fl);

        sum_sq_nat_r += @as(f64, nr) * @as(f64, nr);
        sum_sq_ff_r += @as(f64, fr) * @as(f64, fr);
        err_r += er * er;
        dot_r += @as(f64, nr) * @as(f64, fr);

        const dl = @abs(nl - fl);
        const dr = @abs(nr - fr);
        if (dl > max_diff_all) max_diff_all = dl;
        if (dr > max_diff_all) max_diff_all = dr;
    }

    const denom_all = std.math.sqrt(sum_sq_nat_all * sum_sq_ff_all);
    const overall: SegmentStats = .{
        .start_time = 0.0,
        .end_time = @as(f64, @floatFromInt(nat_aligned.len / 2)) / 48000.0,
        .sample_count = nat_aligned.len / 2,
        .rms_native = std.math.sqrt(sum_sq_nat_all / @as(f64, @floatFromInt(nat_aligned.len))),
        .rms_ffmpeg = std.math.sqrt(sum_sq_ff_all / @as(f64, @floatFromInt(ff_aligned.len))),
        .max_abs_diff = max_diff_all,
        .snr_db = if (sum_sq_err_all > 1e-15) 10.0 * std.math.log10(sum_sq_ff_all / sum_sq_err_all) else 120.0,
        .correlation = if (denom_all > 1e-15) dot_all / denom_all else 0.0,
    };

    const corr_l = if (sum_sq_nat_l * sum_sq_ff_l > 1e-15) dot_l / std.math.sqrt(sum_sq_nat_l * sum_sq_ff_l) else 0.0;
    const corr_r = if (sum_sq_nat_r * sum_sq_ff_r > 1e-15) dot_r / std.math.sqrt(sum_sq_nat_r * sum_sq_ff_r) else 0.0;
    const rms_nat_l = std.math.sqrt(sum_sq_nat_l / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const rms_nat_r = std.math.sqrt(sum_sq_nat_r / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const rms_ff_l = std.math.sqrt(sum_sq_ff_l / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const rms_ff_r = std.math.sqrt(sum_sq_ff_r / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const snr_l = if (err_l > 1e-15) 10.0 * std.math.log10(sum_sq_ff_l / err_l) else 120.0;
    const snr_r = if (err_r > 1e-15) 10.0 * std.math.log10(sum_sq_ff_r / err_r) else 120.0;

    std.debug.print(
        \\[PER-CHANNEL METRICS: AAC {s}]
        \\  Left Ch:  Native RMS={d:.6}, FFmpeg RMS={d:.6} | Corr r={d:.7} | SNR={d:.2} dB
        \\  Right Ch: Native RMS={d:.6}, FFmpeg RMS={d:.6} | Corr r={d:.7} | SNR={d:.2} dB
        \\
    , .{
        label,
        rms_nat_l,
        rms_ff_l,
        corr_l,
        snr_l,
        rms_nat_r,
        rms_ff_r,
        corr_r,
        snr_r,
    });

    // 5. Display terminal results table and graph
    printTerminalReport(label, file_path, overall, segment_stats, success_frames, failed_frames);

    // 6. Generate interactive HTML visual waveform graph report in tmp/
    generateHtmlReport(io, allocator, report_filename, label, file_path, overall, segment_stats, nat_aligned, ff_aligned, success_frames, failed_frames) catch |err| {
        std.debug.print("Notice: could not write HTML report to {s}: {}\n", .{ report_filename, err });
    };
    std.debug.print("[HTML Report] Generated visual waveform report at: {s}\n", .{report_filename});

    // 7. Quality observation notice
    if (failed_frames > 0 or overall.correlation < 0.99) {
        std.debug.print("\n[AAC Quality Notice] Decoder health: {d} failed frames, overall correlation r={d:.4}.\nInspect {s} for waveform visualization.\n\n", .{
            failed_frames, overall.correlation, report_filename,
        });
    }
}

test "AacDecoder test_video_aac_51.mkv vs FFmpeg reference" {
    const testing = std.testing;
    try runAacTest(testing.allocator, testing.io, "testvideo/test_video_aac_51.mkv", "5.1 Surround", "tmp/aac_51_decoding_report.html", 6);
}

test "AacDecoder diagnose lockstep test_video_aac_51" {
    const allocator = std.testing.allocator;
    const file_path = "testvideo/test_video_aac_51.mkv";

    var in_fmt_ctx: ?*c.AVFormatContext = null;
    const c_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_path);

    if (c.avformat_open_input(&in_fmt_ctx, c_path.ptr, null, null) < 0) return error.OpenFailed;
    defer c.avformat_close_input(&in_fmt_ctx);
    if (c.avformat_find_stream_info(in_fmt_ctx.?, null) < 0) return error.FindStreamFailed;

    var a_idx: ?usize = null;
    for (0..in_fmt_ctx.?.nb_streams) |i| {
        if (in_fmt_ctx.?.streams[i].*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO) {
            a_idx = i;
            break;
        }
    }
    const audio_stream = in_fmt_ctx.?.streams[a_idx.?];
    const codec = c.avcodec_find_decoder(audio_stream.*.codecpar.*.codec_id) orelse return error.NoDecoder;
    var codec_ctx = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
    defer c.avcodec_free_context(&codec_ctx);
    if (c.avcodec_parameters_to_context(codec_ctx, audio_stream.*.codecpar) < 0) return error.ParamFailed;
    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.OpenCodecFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&pkt);
    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);

    var native_dec = aac_dec.AacDecoder.init();
    native_dec.sample_rate = 48000;
    native_dec.channels = 6;

    std.debug.print("\n=== LOCKSTEP PACKET TRACE (test_video_aac_51.mkv) ===\n", .{});

    var pkt_count: usize = 0;
    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index != @as(c_int, @intCast(a_idx.?))) continue;
        defer pkt_count += 1;
        if (pkt_count >= 15) break;

        const raw_bytes: []const u8 = pkt.*.data[0..@intCast(pkt.*.size)];

        var nat_stereo: [2048]f32 = undefined;
        const n_nat = native_dec.decodeFrame(raw_bytes, &nat_stereo) catch |err| {
            std.debug.print("  Pkt #{d} pts={d}: Native decode error {}\n", .{ pkt_count, pkt.*.pts, err });
            continue;
        };

        _ = c.avcodec_send_packet(codec_ctx, pkt);
        while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
            const nb: usize = @intCast(frame.*.nb_samples);
            const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));

            const nat_c = native_dec.last_ch_pcm[2];
            const ff_c = data[2][0..nb];

            var sum_prod: f64 = 0; var sum_n2: f64 = 0; var sum_f2: f64 = 0;
            for (0..1024) |s| {
                const nv: f64 = @as(f64, nat_c[s]) * (1.0 / 65536.0);
                const fv: f64 = @as(f64, ff_c[s]);
                sum_prod += nv * fv; sum_n2 += nv * nv; sum_f2 += fv * fv;
            }
            const rms_n = std.math.sqrt(sum_n2 / 1024.0);
            const rms_f = std.math.sqrt(sum_f2 / 1024.0);
            const r = if (sum_n2 > 0 and sum_f2 > 0) sum_prod / std.math.sqrt(sum_n2 * sum_f2) else 0.0;

            const nat_fl = native_dec.last_ch_pcm[0];
            const ff_fl = data[0][0..nb];
            var sum_prod_fl: f64 = 0; var sum_n2_fl: f64 = 0; var sum_f2_fl: f64 = 0;
            for (0..1024) |s| {
                const nv: f64 = @as(f64, nat_fl[s]) * (1.0 / 65536.0);
                const fv: f64 = @as(f64, ff_fl[s]);
                sum_prod_fl += nv * fv; sum_n2_fl += nv * nv; sum_f2_fl += fv * fv;
            }
            const r_fl = if (sum_n2_fl > 0 and sum_f2_fl > 0) sum_prod_fl / std.math.sqrt(sum_n2_fl * sum_f2_fl) else 0.0;
            std.debug.print("Pkt #{d:>2} (pts={d:>3}): Center RMS Nat={d:.5} FF={d:.5} r={d:.6} | FL r={d:.6} (nat_samples={d})\n", .{
                pkt_count, frame.*.pts, rms_n, rms_f, r, r_fl, n_nat,
            });
            if (pkt_count >= 3 and pkt_count <= 8) {
                std.debug.print("    Nat C start: ", .{});
                for (0..8) |s| std.debug.print("{d:.4} ", .{@as(f64, nat_c[s]) * (-1.0 / 65536.0)});
                std.debug.print("\n    FF  C start: ", .{});
                for (0..8) |s| std.debug.print("{d:.4} ", .{ff_c[s]});
                std.debug.print("\n    Nat C end:   ", .{});
                for (1016..1024) |s| std.debug.print("{d:.4} ", .{@as(f64, nat_c[s]) * (-1.0 / 65536.0)});
                std.debug.print("\n    FF  C end:   ", .{});
                for (1016..1024) |s| std.debug.print("{d:.4} ", .{ff_c[s]});
                std.debug.print("\n", .{});
            }
        }
    }
}
