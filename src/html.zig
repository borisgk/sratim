const std = @import("std");

/// Frontend HTML markup and embedded JavaScript for the custom video player.
pub fn generatePlayerHtml(allocator: std.mem.Allocator, file_name: []const u8, duration: f64, codec_str: []const u8) ![]u8 {
    const min = @as(u32, @intFromFloat(duration)) / 60;
    const sec = @as(u32, @intFromFloat(duration)) % 60;
    const time_str = try std.fmt.allocPrint(allocator, "{d}:{d:0>2}", .{ min, sec });
    defer allocator.free(time_str);

    return try std.fmt.allocPrint(allocator,
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\    <title>Sratim Stream</title>
        \\    <style>
        \\        body {{ margin: 0; background: #000; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; font-family: sans-serif; color: white; }}
        \\        .player-wrapper {{ position: relative; width: 80%; max-width: 1280px; }}
        \\        video {{ width: 100%; display: block; }}
        \\        .controls {{ display: flex; align-items: center; padding: 10px; background: #222; }}
        \\        button {{ background: #444; color: white; border: none; padding: 10px; cursor: pointer; }}
        \\        .seek-bar {{ flex: 1; margin: 0 10px; cursor: pointer; height: 10px; background: #444; position: relative; }}
        \\        .seek-fill {{ background: #f00; height: 100%; width: 0%; pointer-events: none; }}
        \\        .time {{ font-variant-numeric: tabular-nums; }}
        \\    </style>
        \\</head>
        \\<body>
        \\    <div class="player-wrapper">
        \\        <video id="video" autoplay playsinline></video>
        \\        <div class="controls">
        \\            <button id="playpause">Pause</button>
        \\            <div class="time" id="time-current">0:00</div>
        \\            <div class="seek-bar" id="seekbar">
        \\                <div class="seek-fill" id="seekfill"></div>
        \\            </div>
        \\            <div class="time" id="time-total">{s}</div>
        \\        </div>
        \\    </div>
        \\    <script>
        \\        const video = document.getElementById('video');
        \\        const playpause = document.getElementById('playpause');
        \\        const seekbar = document.getElementById('seekbar');
        \\        const seekfill = document.getElementById('seekfill');
        \\        const timeCurrent = document.getElementById('time-current');
        \\        
        \\        const DURATION = {d}; // Real duration
        \\        const fileName = "{s}";
        \\        const codecStr = "{s}";
        \\        let currentSeekTime = 0;
        \\        let abortController = null;
        \\
        \\        function formatTime(seconds) {{
        \\            const m = Math.floor(seconds / 60);
        \\            const s = Math.floor(seconds % 60);
        \\            return m + ':' + (s < 10 ? '0' : '') + s;
        \\        }}
        \\
        \\        async function fetchAndAppend(sourceBuffer, startTime, signal) {{
        \\            try {{
        \\                const response = await fetch(`/stream?file=${{encodeURIComponent(fileName)}}&start=${{startTime}}`, {{ signal }});
        \\                const reader = response.body.getReader();
        \\
        \\                while (!signal.aborted) {{
        \\                    // Pause if buffer is far ahead (120 seconds)
        \\                    if (sourceBuffer.buffered.length > 0) {{
        \\                        const end = sourceBuffer.buffered.end(sourceBuffer.buffered.length - 1);
        \\                        if (end - video.currentTime > 120) {{
        \\                            await new Promise(r => setTimeout(r, 1000));
        \\                            continue;
        \\                        }}
        \\                    }}
        \\
        \\                    const {{done, value}} = await reader.read();
        \\                    if (done) break;
        \\
        \\                    let appended = false;
        \\                    while (!appended && !signal.aborted) {{
        \\                        if (sourceBuffer.updating) {{
        \\                            await new Promise(r => setTimeout(r, 50));
        \\                            continue;
        \\                        }}
        \\                        try {{
        \\                            sourceBuffer.appendBuffer(value);
        \\                            appended = true;
        \\                        }} catch (e) {{
        \\                            if (e.name === 'QuotaExceededError') {{
        \\                                await new Promise(r => setTimeout(r, 1000));
        \\                            }} else {{
        \\                                throw e;
        \\                            }}
        \\                        }}
        \\                    }}
        \\                }}
        \\            }} catch (e) {{
        \\                if (e.name !== 'AbortError') console.error('Fetch error:', e);
        \\            }}
        \\        }}
        \\
        \\        function loadVideo(startTime) {{
        \\            currentSeekTime = startTime;
        \\            
        \\            if (abortController) abortController.abort();
        \\            abortController = new AbortController();
        \\            const signal = abortController.signal;
        \\
        \\            const ms = new MediaSource();
        \\            video.src = URL.createObjectURL(ms);
        \\
        \\            ms.addEventListener('sourceopen', () => {{
        \\                if (signal.aborted) return;
        \\                const sourceBuffer = ms.addSourceBuffer(codecStr);
        \\                fetchAndAppend(sourceBuffer, startTime, signal);
        \\            }});
        \\            
        \\            video.play().catch(e => console.error("Play failed:", e));
        \\        }}
        \\
        \\        video.addEventListener('timeupdate', () => {{
        \\            const actualTime = currentSeekTime + video.currentTime;
        \\            const percentage = (actualTime / DURATION) * 100;
        \\            seekfill.style.width = percentage + '%';
        \\            timeCurrent.innerText = formatTime(actualTime);
        \\        }});
        \\
        \\        playpause.addEventListener('click', () => {{
        \\            if (video.paused) {{
        \\                video.play();
        \\                playpause.innerText = 'Pause';
        \\            }} else {{
        \\                video.pause();
        \\                playpause.innerText = 'Play';
        \\            }}
        \\        }});
        \\
        \\        seekbar.addEventListener('click', (e) => {{
        \\            const rect = seekbar.getBoundingClientRect();
        \\            const percentage = (e.clientX - rect.left) / rect.width;
        \\            const seekTo = Math.max(0, Math.floor(percentage * DURATION));
        \\            loadVideo(seekTo);
        \\        }});
        \\
        \\        // Initial load
        \\        loadVideo(0);
        \\    </script>
        \\</body>
        \\</html>
        \\
    , .{ time_str, duration, file_name, codec_str });
}
