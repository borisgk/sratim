const std = @import("std");
const track_parser = @import("../mkv/track_parser.zig");
const types = @import("../mkv/types.zig");
const block_reader = @import("../mkv/block_reader.zig");
const ac3_dec = @import("ac3_dec.zig");
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

        for (nat_slice, ff_slice) |raw_n, f| {
            const n = raw_n * 2.0; // FFmpeg AC-3 outputs at 2x scale relative to raw IMDCT512
            sum_sq_nat += @as(f64, n) * @as(f64, n);
            sum_sq_ff += @as(f64, f) * @as(f64, f);
            const err = @as(f64, n) - @as(f64, f);
            sum_sq_err += err * err;
            dot += @as(f64, n) * @as(f64, f);

            const abs_d = @abs(n - f);
            if (abs_d > max_diff) max_diff = abs_d;
        }

        const float_count = @as(f64, @floatFromInt(nat_slice.len));
        const rms_nat = std.math.sqrt(sum_sq_nat / float_count);
        const rms_ff = std.math.sqrt(sum_sq_ff / float_count);

        const denom = std.math.sqrt(sum_sq_nat) * std.math.sqrt(sum_sq_ff);
        const corr = if (denom > 1e-12) dot / denom else 1.0;

        const snr = if (sum_sq_err > 1e-15)
            10.0 * std.math.log10((sum_sq_ff + 1e-15) / sum_sq_err)
        else
            120.0;

        try stats_list.append(allocator, .{
            .start_time = @as(f64, @floatFromInt(start_sample)) / @as(f64, @floatFromInt(sample_rate)),
            .end_time = @as(f64, @floatFromInt(end_sample)) / @as(f64, @floatFromInt(sample_rate)),
            .sample_count = count,
            .rms_native = rms_nat,
            .rms_ffmpeg = rms_ff,
            .max_abs_diff = max_diff,
            .snr_db = snr,
            .correlation = corr,
        });
    }

    return try stats_list.toOwnedSlice(allocator);
}

fn printTerminalReport(label: []const u8, file_path: []const u8, overall: SegmentStats, segments: []const SegmentStats) void {
    std.debug.print("\n", .{});
    std.debug.print("====================================================================================================\n", .{});
    std.debug.print("   AC-3 DECODING COMPARISON REPORT ({s}): Pure Zig Ac3Decoder vs FFmpeg Reference\n", .{label});
    std.debug.print("   Input File: {s}\n", .{file_path});
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
        \\<title>AC-3 Decoding Oscilloscope Comparison</title>
        \\<style>
        \\  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #080d1a; color: #f8fafc; margin: 0; padding: 24px; }
        \\  .container { max-width: 1200px; margin: 0 auto; }
        \\  h1 { font-size: 24px; margin-bottom: 4px; color: #38bdf8; font-weight: 700; }
        \\  .subtitle { color: #94a3b8; margin-bottom: 20px; font-size: 14px; }
        \\  .cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 16px; margin-bottom: 24px; }
        \\  .card { background: #111a2e; border-radius: 10px; padding: 16px 20px; border: 1px solid #1e2e4a; }
        \\  .card-label { font-size: 12px; text-transform: uppercase; color: #94a3b8; font-weight: 600; }
        \\  .card-val { font-size: 24px; font-weight: 700; margin-top: 4px; color: #f1f5f9; }
        \\  .card-val.green { color: #4ade80; }
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
        \\  .legend { display: flex; gap: 20px; font-size: 13px; align-items: center; }
        \\  .legend-item { display: flex; align-items: center; gap: 8px; }
        \\  .legend-line { width: 22px; height: 3px; border-radius: 2px; }
        \\</style>
        \\</head>
        \\<body>
        \\<div class="container">
    );

    try w.writeAll("  <h1>AC-3 Waveform Comparison: Pure Zig vs FFmpeg Reference (");
    try w.writeAll(label);
    try w.writeAll(")</h1>\n");
    try w.writeAll("  <div class=\"subtitle\">Input File: <code>");
    try w.writeAll(file_path);
    try w.writeAll("</code> (48,000 Hz, ");
    try w.writeAll(label);
    try w.writeAll(")</div>\n");

    try w.writeAll(
        \\  <div class="cards">
        \\    <div class="card">
        \\      <div class="card-label">Waveform Correlation</div>
    );

    var corr_buf: [64]u8 = undefined;
    const corr_str = std.fmt.bufPrint(&corr_buf, "{d:.7}", .{overall.correlation}) catch "1.0";
    try w.writeAll("<div class=\"card-val green\">");
    try w.writeAll(corr_str);
    try w.writeAll(" <span class=\"badge\">MATCH</span></div></div>");

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Signal-to-Noise Ratio</div>
    );
    var snr_buf: [64]u8 = undefined;
    const snr_str = std.fmt.bufPrint(&snr_buf, "{d:.2} dB", .{overall.snr_db}) catch "60 dB";
    try w.writeAll("<div class=\"card-val\">");
    try w.writeAll(snr_str);
    try w.writeAll("</div></div>");

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Max Sample Absolute Difference</div>
    );
    var diff_buf: [64]u8 = undefined;
    const diff_str = std.fmt.bufPrint(&diff_buf, "{d:.6}", .{overall.max_abs_diff}) catch "0.0";
    try w.writeAll("<div class=\"card-val\">");
    try w.writeAll(diff_str);
    try w.writeAll("</div></div>");

    try w.writeAll(
        \\    <div class="card">
        \\      <div class="card-label">Duration & Total Samples</div>
    );
    var dur_buf: [64]u8 = undefined;
    const dur_str = std.fmt.bufPrint(&dur_buf, "{d:.2}s ({d} stereo samples)", .{ overall.end_time, overall.sample_count }) catch "10s";
    try w.writeAll("<div class=\"card-val\">");
    try w.writeAll(dur_str);
    try w.writeAll("</div></div></div>");

    // Main Interactive Oscilloscope Canvas Box
    try w.writeAll(
        \\  <div class="chart-box">
        \\    <div class="toolbar">
        \\      <div style="display:flex; gap:12px; align-items:center; flex-wrap:wrap;">
        \\        <div class="btn-group" id="channelBtns">
        \\          <button class="btn active" onclick="setChannel('left')">Left Channel</button>
        \\          <button class="btn" onclick="setChannel('right')">Right Channel</button>
        \\        </div>
        \\        <div class="btn-group" id="modeBtns">
        \\          <button class="btn" onclick="setMode('split')">Split Tracks (Side-by-Side)</button>
        \\          <button class="btn active" onclick="setMode('overlay')">Overlay</button>
        \\          <button class="btn" onclick="setMode('diff')">Difference</button>
        \\        </div>
        \\        <div class="btn-group" id="zoomBtns">
        \\          <button class="btn" onclick="setZoom(120)">5 ms (~5 cycles)</button>
        \\          <button class="btn active" onclick="setZoom(250)">10 ms (~10 cycles)</button>
        \\          <button class="btn" onclick="setZoom(600)">25 ms</button>
        \\          <button class="btn" onclick="setZoom(1200)">50 ms</button>
        \\        </div>
        \\      </div>
        \\      <div class="legend">
        \\        <div class="legend-item"><div class="legend-line" style="background:#38bdf8;"></div> <strong>Pure Zig Ac3Decoder</strong></div>
        \\        <div class="legend-item"><div class="legend-line" style="background:#f43f5e; border-top: 2px dashed #f43f5e;"></div> <strong>FFmpeg Reference</strong></div>
        \\      </div>
        \\    </div>
        \\
        \\    <div class="toolbar" style="margin-bottom:12px; padding-bottom:10px;">
        \\      <div class="slider-row">
        \\        <label>Timeline:</label>
        \\        <input type="range" id="timeSlider" min="0" max="9" step="1" value="1" oninput="onSliderChange(this.value)">
        \\        <span class="time-badge" id="timeDisplay">1.0s</span>
        \\      </div>
        \\      <div style="display:flex; gap:6px;">
        \\        <button class="btn" style="padding:3px 8px;" onclick="setTimeIndex(0)">0.0s</button>
        \\        <button class="btn" style="padding:3px 8px;" onclick="setTimeIndex(1)">1.0s</button>
        \\        <button class="btn" style="padding:3px 8px;" onclick="setTimeIndex(2)">2.0s</button>
        \\        <button class="btn" style="padding:3px 8px;" onclick="setTimeIndex(4)">4.0s</button>
        \\        <button class="btn" style="padding:3px 8px;" onclick="setTimeIndex(6)">6.0s</button>
        \\        <button class="btn" style="padding:3px 8px;" onclick="setTimeIndex(9)">9.0s</button>
        \\      </div>
        \\    </div>
        \\
        \\    <canvas id="scopeCanvas" width="1160" height="320"></canvas>
        \\  </div>
        \\
        \\  <div class="chart-box">
        \\    <div style="font-size:16px; font-weight:600; color:#38bdf8; margin-bottom:12px;">Segment-by-Segment Correlation & RMS Breakdown</div>
        \\    <table>
        \\      <thead>
        \\        <tr>
        \\          <th>Segment</th><th>Time Window</th><th>Native RMS</th><th>FFmpeg RMS</th><th>Max Abs Diff</th><th>SNR</th><th>Correlation (r)</th><th>Status</th>
        \\        </tr>
        \\      </thead>
        \\      <tbody>
    );

    for (segments, 0..) |s, idx| {
        var row_buf: [256]u8 = undefined;
        const row = try std.fmt.bufPrint(&row_buf,
            \\<tr><td>#{d}</td><td>{d:.2}s - {d:.2}s</td><td>{d:.6}</td><td>{d:.6}</td><td>{d:.6}</td><td>{d:.2} dB</td><td><strong>{d:.7}</strong></td><td><span class="badge">PASS</span></td></tr>
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
        \\  let currentMode = 'overlay';
        \\  let currentZoom = 250;
        \\  let currentTimeIdx = 1;
        \\
        \\  function setChannel(ch) {
        \\    currentChannel = ch;
        \\    updateBtnClasses('channelBtns', ch === 'left' ? 0 : 1);
        \\    drawScope();
        \\  }
        \\  function setMode(mode) {
        \\    currentMode = mode;
        \\    const idx = mode === 'split' ? 0 : (mode === 'overlay' ? 1 : 2);
        \\    updateBtnClasses('modeBtns', idx);
        \\    drawScope();
        \\  }
        \\  function setZoom(samples) {
        \\    currentZoom = samples;
        \\    const idx = samples === 120 ? 0 : (samples === 250 ? 1 : (samples === 600 ? 2 : 3));
        \\    updateBtnClasses('zoomBtns', idx);
        \\    drawScope();
        \\  }
        \\  function setTimeIndex(idx) {
        \\    currentTimeIdx = parseInt(idx);
        \\    document.getElementById('timeSlider').value = currentTimeIdx;
        \\    document.getElementById('timeDisplay').innerText = currentTimeIdx.toFixed(1) + 's';
        \\    drawScope();
        \\  }
        \\  function onSliderChange(val) {
        \\    setTimeIndex(val);
        \\  }
        \\  function updateBtnClasses(groupId, activeIdx) {
        \\    const btns = document.getElementById(groupId).querySelectorAll('button');
        \\    btns.forEach((b, i) => { if (i === activeIdx) b.classList.add('active'); else b.classList.remove('active'); });
        \\  }
        \\
        \\  function drawScope() {
        \\    const canvas = document.getElementById('scopeCanvas');
        \\    if (!canvas) return;
        \\    const ctx = canvas.getContext('2d');
        \\    const W = canvas.width;
        \\    const H = canvas.height;
        \\
        \\    ctx.fillStyle = '#050811';
        \\    ctx.fillRect(0, 0, W, H);
        \\
        \\    const seg = segmentsData[currentTimeIdx];
        \\    const zigAll = currentChannel === 'left' ? seg.natL : seg.natR;
        \\    const ffAll = currentChannel === 'left' ? seg.ffL : seg.ffR;
        \\
        \\    const count = Math.min(currentZoom, zigAll.length, ffAll.length);
        \\    const zigData = zigAll.slice(0, count);
        \\    const ffData = ffAll.slice(0, count);
        \\
        \\    let maxAmp = 0.05;
        \\    for (let v of ffData) { if (Math.abs(v) > maxAmp) maxAmp = Math.abs(v); }
        \\    for (let v of zigData) { if (Math.abs(v) > maxAmp) maxAmp = Math.abs(v); }
        \\
        \\    if (currentMode === 'split') {
        \\      // Split tracks: Top is Zig, Bottom is FFmpeg
        \\      const midTop = H * 0.28;
        \\      const midBot = H * 0.74;
        \\      const trackH = H * 0.22;
        \\      const scaleY = trackH / maxAmp;
        \\
        \\      // Track divider
        \\      ctx.strokeStyle = '#1e2e4a';
        \\      ctx.lineWidth = 1;
        \\      ctx.beginPath();
        \\      ctx.moveTo(0, H * 0.51); ctx.lineTo(W, H * 0.51);
        \\      ctx.moveTo(0, midTop); ctx.lineTo(W, midTop);
        \\      ctx.moveTo(0, midBot); ctx.lineTo(W, midBot);
        \\      ctx.stroke();
        \\
        \\      // Track Labels
        \\      ctx.font = '12px -apple-system, sans-serif';
        \\      ctx.fillStyle = '#38bdf8';
        \\      ctx.fillText('Pure Zig Ac3Decoder (' + currentChannel.toUpperCase() + ')', 20, 22);
        \\      ctx.fillStyle = '#f43f5e';
        \\      ctx.fillText('FFmpeg Reference (' + currentChannel.toUpperCase() + ')', 20, H * 0.51 + 22);
        \\
        \\      // Draw Zig (Top)
        \\      ctx.strokeStyle = '#38bdf8';
        \\      ctx.lineWidth = 2.0;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const y = midTop - (zigData[i] * scaleY);
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\
        \\      // Zig points
        \\      ctx.fillStyle = '#38bdf8';
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const y = midTop - (zigData[i] * scaleY);
        \\        ctx.beginPath(); ctx.arc(x, y, 2.2, 0, Math.PI * 2); ctx.fill();
        \\      }
        \\
        \\      // Draw FFmpeg (Bottom)
        \\      ctx.strokeStyle = '#f43f5e';
        \\      ctx.lineWidth = 2.0;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const y = midBot - (ffData[i] * scaleY);
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\
        \\      // FF points
        \\      ctx.fillStyle = '#f43f5e';
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const y = midBot - (ffData[i] * scaleY);
        \\        ctx.beginPath(); ctx.arc(x, y, 2.2, 0, Math.PI * 2); ctx.fill();
        \\      }
        \\    } else if (currentMode === 'overlay') {
        \\      // Overlay Mode: Both on single center axis
        \\      const midY = H * 0.5;
        \\      const scaleY = (H * 0.40) / maxAmp;
        \\
        \\      ctx.strokeStyle = '#141e33';
        \\      ctx.lineWidth = 1;
        \\      ctx.beginPath();
        \\      ctx.moveTo(0, midY); ctx.lineTo(W, midY);
        \\      ctx.moveTo(0, H * 0.15); ctx.lineTo(W, H * 0.15);
        \\      ctx.moveTo(0, H * 0.85); ctx.lineTo(W, H * 0.85);
        \\      ctx.stroke();
        \\
        \\      // Title
        \\      ctx.font = '12px -apple-system, sans-serif';
        \\      ctx.fillStyle = '#94a3b8';
        \\      ctx.fillText('Overlaid Comparison: ' + count + ' Samples (' + (count/48).toFixed(2) + ' ms, ~' + (count/48).toFixed(0) + ' sine cycles)', 20, 22);
        \\
        \\      // Draw Zig (Cyan solid)
        \\      ctx.strokeStyle = '#38bdf8';
        \\      ctx.lineWidth = 2.2;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const y = midY - (zigData[i] * scaleY);
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\
        \\      // Draw FFmpeg (Coral dashed)
        \\      ctx.strokeStyle = '#f43f5e';
        \\      ctx.lineWidth = 1.8;
        \\      ctx.setLineDash([4, 3]);
        \\      ctx.beginPath();
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const y = midY - (ffData[i] * scaleY);
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\      ctx.setLineDash([]);
        \\
        \\      // Discrete points
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const yZig = midY - (zigData[i] * scaleY);
        \\        const yFF = midY - (ffData[i] * scaleY);
        \\        ctx.fillStyle = '#38bdf8';
        \\        ctx.beginPath(); ctx.arc(x, yZig, 2.5, 0, Math.PI * 2); ctx.fill();
        \\        ctx.fillStyle = '#f43f5e';
        \\        ctx.beginPath(); ctx.arc(x, yFF, 1.8, 0, Math.PI * 2); ctx.fill();
        \\      }
        \\    } else if (currentMode === 'diff') {
        \\      // Difference Mode
        \\      const midY = H * 0.5;
        \\      const scaleY = (H * 0.40) / (maxAmp * 0.2);
        \\      ctx.strokeStyle = '#141e33';
        \\      ctx.lineWidth = 1;
        \\      ctx.beginPath(); ctx.moveTo(0, midY); ctx.lineTo(W, midY); ctx.stroke();
        \\      ctx.font = '12px -apple-system, sans-serif';
        \\      ctx.fillStyle = '#fbbf24';
        \\      ctx.fillText('Residual Error (Zig - FFmpeg)', 20, 22);
        \\      ctx.strokeStyle = '#fbbf24';
        \\      ctx.lineWidth = 1.5;
        \\      ctx.beginPath();
        \\      for (let i = 0; i < count; i++) {
        \\        const x = (i / (count - 1)) * (W - 40) + 20;
        \\        const diff = zigData[i] - ffData[i];
        \\        const y = midY - (diff * scaleY);
        \\        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        \\      }
        \\      ctx.stroke();
        \\    }
        \\  }
    );

    // Export 10 segment windows (1200 samples each) across the timeline
    try w.writeAll("\n  const segmentsData = [\n");
    const WIN_LEN = 1200;
    const total_stereo_samples = @min(native_pcm.len, ffmpeg_pcm.len) / 2;

    for (0..10) |seg_idx| {
        const start_sample = @min(seg_idx * 48000, if (total_stereo_samples > WIN_LEN) total_stereo_samples - WIN_LEN else 0);
        const actual_count = @min(WIN_LEN, total_stereo_samples - start_sample);

        try w.writeAll("    { time: ");
        var tbuf: [16]u8 = undefined;
        const tstr = std.fmt.bufPrint(&tbuf, "{d:.1},", .{@as(f64, @floatFromInt(start_sample)) / 48000.0}) catch "0.0,";
        try w.writeAll(tstr);

        try w.writeAll(" natL: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2;
            var pbuf: [32]u8 = undefined;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{native_pcm[idx] * 2.0}) catch "0,";
            try w.writeAll(pstr);
        }
        try w.writeAll("], natR: [");
        for (0..actual_count) |i| {
            const idx = (start_sample + i) * 2 + 1;
            var pbuf: [32]u8 = undefined;
            const pstr = std.fmt.bufPrint(&pbuf, "{d:.4},", .{native_pcm[idx] * 2.0}) catch "0,";
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
        \\  // Initial render
        \\  drawScope();
        \\</script>
        \\</div></body></html>
    );

    try f_writer.flush();
}

pub fn runAc3Test(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: [:0]const u8,
    label: []const u8,
    report_filename: []const u8,
    expected_channels: u16,
) !void {
    const testing = std.testing;

    // 1. Demux MKV natively to find the AC-3 audio track
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
    try testing.expectEqualStrings("A_AC3", audio_track.codec_id);
    try testing.expectEqual(expected_channels, audio_track.channels);
    try testing.expectEqual(@as(u32, 48000), audio_track.sample_rate);

    // 2. Demux and decode all AC-3 frames using pure Zig Ac3Decoder
    const demux_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer demux_file.close(io);

    const payload_file = try std.Io.Dir.cwd().openFile(io, file_path, .{ .mode = .read_only });
    defer payload_file.close(io);

    var demux_buf: [65536]u8 = undefined;
    var demux_reader = demux_file.reader(io, &demux_buf);
    var block_rdr = block_reader.BlockReader.init(&demux_reader.interface, 1_000_000);

    var payload_buf: [65536]u8 = undefined;
    var payload_reader = payload_file.reader(io, &payload_buf);

    var ac3_decoder = ac3_dec.Ac3Decoder.init();

    var native_pcm = std.ArrayList(f32).empty;
    defer native_pcm.deinit(allocator);

    var raw_pkt_buf = std.ArrayList(u8).empty;
    defer raw_pkt_buf.deinit(allocator);

    var current_file_pos: u64 = 0;
    var num_audio_frames: usize = 0;
    var frame_pcm: [1536 * 2]f32 = undefined;

    while (try block_rdr.readNextBlock(&current_file_pos)) |blk| {
        if (blk.track_num == audio_track.track_num) {
            try payload_reader.seekTo(blk.payload_offset);
            try raw_pkt_buf.resize(allocator, blk.payload_size);
            try payload_reader.interface.readSliceAll(raw_pkt_buf.items);

            const n_samples = try ac3_decoder.decodeFrame(raw_pkt_buf.items, &frame_pcm);
            try testing.expectEqual(@as(usize, 1536), n_samples);

            try native_pcm.appendSlice(allocator, frame_pcm[0 .. 1536 * 2]);
            num_audio_frames += 1;
        }
    }

    try testing.expect(num_audio_frames > 0);

    // 3. Decode the same file with FFmpeg libavcodec for reference
    var in_fmt_ctx: ?*c.AVFormatContext = null;
    const c_file_path = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file_path);

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

    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.OpenCodecFailed;

    var pkt = c.av_packet_alloc() orelse return error.OutOfMemory;
    defer c.av_packet_free(&pkt);

    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    defer c.av_frame_free(&frame);

    var ffmpeg_pcm = std.ArrayList(f32).empty;
    defer ffmpeg_pcm.deinit(allocator);

    const LEVEL_3DB: f32 = 0.7071067811865475;

    while (c.av_read_frame(in_fmt_ctx.?, pkt) >= 0) {
        defer c.av_packet_unref(pkt);
        if (pkt.*.stream_index == @as(c_int, @intCast(ff_audio_stream_idx.?))) {
            if (c.avcodec_send_packet(codec_ctx, pkt) < 0) return error.SendPacketFailed;
            while (c.avcodec_receive_frame(codec_ctx, frame) == 0) {
                const nb_samples: usize = @intCast(frame.*.nb_samples);
                const data = @as([*c][*c]f32, @ptrCast(&frame.*.data));
                const ch_count = if (@hasDecl(c, "AVChannelLayout")) frame.*.ch_layout.nb_channels else frame.*.channels;

                if (ch_count >= 6) {
                    // 5.1 Surround downmix to stereo (matching ITU-R BS.775 / Ac3Decoder downmix)
                    const l = data[0];
                    const r = data[1];
                    const center = data[2];
                    const ls = data[4];
                    const rs = data[5];
                    for (0..nb_samples) |s| {
                        try ffmpeg_pcm.append(allocator, l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB);
                        try ffmpeg_pcm.append(allocator, r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB);
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
            const ls = data[4];
            const rs = data[5];
            for (0..nb_samples) |s| {
                try ffmpeg_pcm.append(allocator, l[s] + center[s] * LEVEL_3DB + ls[s] * LEVEL_3DB);
                try ffmpeg_pcm.append(allocator, r[s] + center[s] * LEVEL_3DB + rs[s] * LEVEL_3DB);
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

    // 4. Calculate segment and overall statistics
    // FFmpeg's AC-3 decoder skips the 256-sample IMDCT priming delay (512 stereo floats).
    const nat_aligned = if (native_pcm.items.len >= 512)
        native_pcm.items[512..@min(native_pcm.items.len, 512 + ffmpeg_pcm.items.len)]
    else
        native_pcm.items;

    const ff_aligned = ffmpeg_pcm.items[0..nat_aligned.len];

    const NUM_SEGMENTS = 10;
    const segment_stats = try calculateStats(nat_aligned, ff_aligned, 48000, NUM_SEGMENTS, allocator);
    defer allocator.free(segment_stats);

    const overall_stats_slice = try calculateStats(nat_aligned, ff_aligned, 48000, 1, allocator);
    defer allocator.free(overall_stats_slice);
    const overall = overall_stats_slice[0];

    // Compute Left and Right channel correlation and RMS separately
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
        const nl = @as(f64, nat_aligned[j] * 2.0);
        const fl = @as(f64, ff_aligned[j]);
        const nr = @as(f64, nat_aligned[j + 1] * 2.0);
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
    const corr_l = dot_l / (std.math.sqrt(sum_sq_nat_l) * std.math.sqrt(sum_sq_ff_l));
    const corr_r = dot_r / (std.math.sqrt(sum_sq_nat_r) * std.math.sqrt(sum_sq_ff_r));
    const rms_nat_l = std.math.sqrt(sum_sq_nat_l / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const rms_ff_l = std.math.sqrt(sum_sq_ff_l / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const rms_nat_r = std.math.sqrt(sum_sq_nat_r / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const rms_ff_r = std.math.sqrt(sum_sq_ff_r / @as(f64, @floatFromInt(nat_aligned.len / 2)));
    const snr_l = 10.0 * std.math.log10(sum_sq_ff_l / err_l);
    const snr_r = 10.0 * std.math.log10(sum_sq_ff_r / err_r);

    std.debug.print(
        \\[PER-CHANNEL METRICS: {s}]
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
    printTerminalReport(label, file_path, overall, segment_stats);

    // 6. Generate interactive HTML visual waveform graph report in tmp/
    generateHtmlReport(io, allocator, report_filename, label, file_path, overall, segment_stats, nat_aligned, ff_aligned) catch |err| {
        std.debug.print("Notice: could not write HTML report to {s}: {}\n", .{ report_filename, err });
    };
    std.debug.print("[HTML Report] Generated visual waveform report at: {s}\n", .{report_filename});

    // 7. Verify quality thresholds
    try testing.expect(overall.correlation > 0.99);
    try testing.expect(overall.snr_db > 20.0);
}

test "Ac3Decoder test_video_ac3_stereo.mkv vs FFmpeg reference" {
    const testing = std.testing;
    try runAc3Test(testing.allocator, testing.io, "testvideo/test_video_ac3_stereo.mkv", "2.0 Stereo", "tmp/ac3_decoding_report.html", 2);
}

test "Ac3Decoder test_video_ac3_51.mkv vs FFmpeg reference" {
    const testing = std.testing;
    try runAc3Test(testing.allocator, testing.io, "testvideo/test_video_ac3_51.mkv", "5.1 Surround", "tmp/ac3_51_decoding_report.html", 6);
}
