/// Frontend HTML markup and embedded JavaScript for the custom video player.
pub const INDEX_HTML = 
\\<!DOCTYPE html>
\\<html>
\\<head>
\\    <title>Sratim Stream</title>
\\    <style>
\\        body { margin: 0; background: #000; display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100vh; font-family: sans-serif; color: white; }
\\        .player-wrapper { position: relative; width: 80%; max-width: 1280px; }
\\        video { width: 100%; display: block; }
\\        .controls { display: flex; align-items: center; padding: 10px; background: #222; }
\\        button { background: #444; color: white; border: none; padding: 10px; cursor: pointer; }
\\        .seek-bar { flex: 1; margin: 0 10px; cursor: pointer; height: 10px; background: #444; position: relative; }
\\        .seek-fill { background: #f00; height: 100%; width: 0%; pointer-events: none; }
\\        .time { font-variant-numeric: tabular-nums; }
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
\\            <div class="time" id="time-total">46:39</div>
\\        </div>
\\    </div>
\\    <script>
\\        const video = document.getElementById('video');
\\        const playpause = document.getElementById('playpause');
\\        const seekbar = document.getElementById('seekbar');
\\        const seekfill = document.getElementById('seekfill');
\\        const timeCurrent = document.getElementById('time-current');
\\        const timeTotal = document.getElementById('time-total');
\\        
\\        let currentSeekTime = 0;
\\        const DURATION = 2799; // 46:39 in seconds
\\
\\        function formatTime(seconds) {
\\            const m = Math.floor(seconds / 60);
\\            const s = Math.floor(seconds % 60);
\\            return m + ':' + (s < 10 ? '0' : '') + s;
\\        }
\\
\\        const urlParams = new URLSearchParams(window.location.search);
\\        const fileName = urlParams.get('file') || 'Action/H264.mkv';
\\
\\        function loadVideo(startTime) {
\\            currentSeekTime = startTime;
\\            video.src = `/stream?file=${encodeURIComponent(fileName)}&start=${startTime}`;
\\            video.play();
\\        }
\\
\\        video.addEventListener('timeupdate', () => {
\\            const actualTime = currentSeekTime + video.currentTime;
\\            const percentage = (actualTime / DURATION) * 100;
\\            seekfill.style.width = percentage + '%';
\\            timeCurrent.innerText = formatTime(actualTime);
\\        });
\\
\\        playpause.addEventListener('click', () => {
\\            if (video.paused) {
\\                video.play();
\\                playpause.innerText = 'Pause';
\\            } else {
\\                video.pause();
\\                playpause.innerText = 'Play';
\\            }
\\        });
\\
\\        seekbar.addEventListener('click', (e) => {
\\            const rect = seekbar.getBoundingClientRect();
\\            const percentage = (e.clientX - rect.left) / rect.width;
\\            const seekTo = Math.max(0, Math.floor(percentage * DURATION));
\\            loadVideo(seekTo);
\\        });
\\
\\        // Initial load
\\        loadVideo(0);
\\    </script>
\\</body>
\\</html>
;
