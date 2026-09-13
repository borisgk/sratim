// =========================================================================
// Statistics for Sysadmins (Stats for Nerds) Overlay Module
// Modular, plug-in telemetry engine for Sratim Web Player
// =========================================================================

(function () {
    const DEFAULT_STREAM_ENGINE = '__STREAMER_MODE__';
    const DEFAULT_AUDIO_ENGINE = '__AUDIO_TRANSCODER_MODE__';

    // Telemetry state
    const statsState = {
        isOpen: false,
        timerId: null,
        totalBytesDownloaded: 0,
        streamEngine: DEFAULT_STREAM_ENGINE,
        audioEngine: DEFAULT_AUDIO_ENGINE,
        origAudioCodec: '',
        actualStartTime: null,
        networkActivity: 'Idle',
        recentChunks: [], // { time: ms, bytes: number }
        lastSpeedKbps: 0,
        bufferHistory: [], // { time: ms, buffer: number, isStreaming: boolean }
    };

    let lastBufferSampleTime = 0;

    function getForwardBuffer() {
        let forwardBuffer = 0;
        try {
            const buf = (typeof currentSourceBuffer !== 'undefined' && currentSourceBuffer && currentSourceBuffer.buffered)
                ? currentSourceBuffer.buffered
                : (typeof video !== 'undefined' && video ? video.buffered : null);

            if (buf && typeof video !== 'undefined' && video && typeof video.currentTime === 'number') {
                const curTime = video.currentTime;
                for (let i = 0; i < buf.length; i++) {
                    if (curTime >= buf.start(i) && curTime <= buf.end(i)) {
                        forwardBuffer = Math.max(0, buf.end(i) - curTime);
                        break;
                    }
                }
            }
        } catch (e) {}
        return forwardBuffer;
    }

    function recordBufferSample() {
        const now = performance.now();
        const forwardBuffer = getForwardBuffer();
        const isStreaming = (statsState.networkActivity === 'Streaming') && (now - (statsState.lastChunkTime || 0) < 1500);

        // Avoid pushing redundant samples when polled closely within 400ms
        if (now - lastBufferSampleTime < 400 && statsState.bufferHistory.length > 0) {
            const last = statsState.bufferHistory[statsState.bufferHistory.length - 1];
            last.buffer = forwardBuffer;
            last.isStreaming = last.isStreaming || isStreaming;
            return forwardBuffer;
        }

        lastBufferSampleTime = now;
        statsState.bufferHistory.push({
            time: now,
            buffer: forwardBuffer,
            isStreaming: isStreaming,
        });

        // Retain rolling window of 90 seconds (90,000 ms)
        const cutoff = now - 90000;
        while (statsState.bufferHistory.length > 0 && statsState.bufferHistory[0].time < cutoff) {
            statsState.bufferHistory.shift();
        }

        return forwardBuffer;
    }

    // Keep background buffer history alive so opening the panel immediately shows past timeline
    setInterval(recordBufferSample, 500);

    // Public hooks for StreamEngine telemetry
    window.__onStreamResponse = function (response) {
        try {
            const se = response.headers.get('x-stream-engine');
            if (se) statsState.streamEngine = se;

            const ae = response.headers.get('x-audio-engine');
            if (ae) statsState.audioEngine = ae;

            const oac = response.headers.get('x-original-audio-codec');
            if (oac) statsState.origAudioCodec = oac;

            const ast = response.headers.get('x-actual-start-time');
            if (ast) statsState.actualStartTime = parseFloat(ast);

            statsState.networkActivity = 'Streaming';
            statsState.lastChunkTime = performance.now();
        } catch (e) {}
    };

    window.__onStreamChunk = function (byteLength) {
        if (!byteLength) return;
        const now = performance.now();
        statsState.totalBytesDownloaded += byteLength;
        statsState.networkActivity = 'Streaming';
        statsState.lastChunkTime = now;
        statsState.recentChunks.push({ time: now, bytes: byteLength });

        // Retain rolling window of last 3 seconds for speed calculation
        const cutoff = now - 3000;
        while (statsState.recentChunks.length > 0 && statsState.recentChunks[0].time < cutoff) {
            statsState.recentChunks.shift();
        }
    };

    window.__onStreamState = function (state) {
        statsState.networkActivity = state;
    };

    function calculateSpeedKbps() {
        const now = performance.now();
        const cutoff = now - 3000;
        while (statsState.recentChunks.length > 0 && statsState.recentChunks[0].time < cutoff) {
            statsState.recentChunks.shift();
        }

        if (statsState.recentChunks.length < 2) {
            if (statsState.networkActivity === 'Streaming') {
                return statsState.lastSpeedKbps;
            }
            return 0;
        }

        let totalBytes = 0;
        for (const c of statsState.recentChunks) {
            totalBytes += c.bytes;
        }
        const timeSpanSec = (now - statsState.recentChunks[0].time) / 1000;
        if (timeSpanSec <= 0.05) return statsState.lastSpeedKbps;

        const speedKbps = Math.round((totalBytes * 8) / (timeSpanSec * 1000));
        statsState.lastSpeedKbps = speedKbps;
        return speedKbps;
    }

    // --- DOM Construction ---
    let panelEl = null;
    let fields = {};

    function createStatsPanel() {
        if (panelEl) return panelEl;

        const wrapper = document.querySelector('.player-wrapper') || document.body;

        panelEl = document.createElement('div');
        panelEl.id = 'stats-panel';
        panelEl.className = 'stats-panel hidden';

        panelEl.innerHTML = `
            <div class="stats-header">
                <div class="stats-title-wrap">
                    <span class="stats-icon">
                        <svg viewBox="0 0 24 24" fill="currentColor" width="14" height="14">
                            <path d="M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm0 16H5V5h14v14zM7 10h2v7H7zm4-3h2v10h-2zm4 6h2v4h-2z"/>
                        </svg>
                    </span>
                    <span class="stats-title">Stats for Sysadmins</span>
                    <span class="stats-shortcut-badge">D</span>
                </div>
                <button class="stats-close-btn" id="stats-close-btn" title="Close (Escape or D)">✕</button>
            </div>
            <div class="stats-grid">
                <div class="stats-label">Video ID / Title</div>
                <div class="stats-value" id="sf-video-id">-</div>

                <div class="stats-label">Viewport / Frames</div>
                <div class="stats-value" id="sf-viewport-frames">-</div>

                <div class="stats-label">Current / Stream Res</div>
                <div class="stats-value" id="sf-resolution">-</div>

                <div class="stats-label">Playback State</div>
                <div class="stats-value" id="sf-play-state">-</div>

                <div class="stats-label">Volume / State</div>
                <div class="stats-value" id="sf-volume">-</div>

                <div class="stats-label">Stream Codecs (MSE)</div>
                <div class="stats-value" id="sf-codecs">-</div>

                <div class="stats-label">Original Audio Codec</div>
                <div class="stats-value" id="sf-orig-audio-codec">-</div>

                <div class="stats-label">Stream Engine</div>
                <div class="stats-value" id="sf-stream-engine">-</div>

                <div class="stats-label">Audio Transcoder</div>
                <div class="stats-value" id="sf-audio-engine">-</div>

                <div class="stats-label">Active Audio Track</div>
                <div class="stats-value" id="sf-audio-track">-</div>

                <div class="stats-label">Active Subtitles</div>
                <div class="stats-value" id="sf-subtitles">-</div>

                <div class="stats-label">Connection Speed</div>
                <div class="stats-value" id="sf-conn-speed">-</div>

                <div class="stats-label">Network Activity</div>
                <div class="stats-value" id="sf-network-activity">-</div>

                <div class="stats-label">Buffer Health</div>
                <div class="stats-value" id="sf-buffer-health">
                    <span id="sf-buffer-sec">0.00 s</span>
                    <div class="stats-meter-wrap">
                        <div class="stats-meter-track">
                            <div class="stats-meter-fill" id="sf-buffer-fill"></div>
                        </div>
                    </div>
                </div>

                <div class="stats-label">Total Transferred</div>
                <div class="stats-value" id="sf-transferred">0.00 MB</div>
            </div>
            <div class="stats-chart-section">
                <div class="stats-chart-header">
                    <div class="stats-chart-title-wrap">
                        <span class="stats-chart-title">Realtime Buffer Timeline (Last 90s)</span>
                    </div>
                    <div class="stats-chart-legend">
                        <span><i class="legend-dot legend-stream"></i>Refill Burst</span>
                        <span><i class="legend-dot legend-buffer"></i>Buffer Level</span>
                    </div>
                </div>
                <div class="stats-chart-canvas-wrap">
                    <canvas id="sf-buffer-canvas"></canvas>
                </div>
            </div>
        `;

        wrapper.appendChild(panelEl);

        fields = {
            videoId: document.getElementById('sf-video-id'),
            viewportFrames: document.getElementById('sf-viewport-frames'),
            resolution: document.getElementById('sf-resolution'),
            playState: document.getElementById('sf-play-state'),
            volume: document.getElementById('sf-volume'),
            codecs: document.getElementById('sf-codecs'),
            origAudioCodec: document.getElementById('sf-orig-audio-codec'),
            streamEngine: document.getElementById('sf-stream-engine'),
            audioEngine: document.getElementById('sf-audio-engine'),
            audioTrack: document.getElementById('sf-audio-track'),
            subtitles: document.getElementById('sf-subtitles'),
            connSpeed: document.getElementById('sf-conn-speed'),
            networkActivity: document.getElementById('sf-network-activity'),
            bufferSec: document.getElementById('sf-buffer-sec'),
            bufferFill: document.getElementById('sf-buffer-fill'),
            transferred: document.getElementById('sf-transferred'),
        };

        const closeBtn = document.getElementById('stats-close-btn');
        if (closeBtn) {
            closeBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                SysadminStats.close();
            });
        }

        return panelEl;
    }

    // --- Realtime Buffer Timeline Chart (Canvas) ---
    function renderBufferChart() {
        const canvas = document.getElementById('sf-buffer-canvas');
        if (!canvas) return;

        const dpr = window.devicePixelRatio || 1;
        const rect = canvas.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return;

        const targetW = Math.round(rect.width * dpr);
        const targetH = Math.round(rect.height * dpr);
        if (canvas.width !== targetW || canvas.height !== targetH) {
            canvas.width = targetW;
            canvas.height = targetH;
        }

        const ctx = canvas.getContext('2d');
        if (!ctx) return;

        ctx.save();
        ctx.scale(dpr, dpr);
        const w = rect.width;
        const h = rect.height;

        ctx.clearRect(0, 0, w, h);

        const history = statsState.bufferHistory;
        const now = performance.now();
        const windowMs = 90000; // 90 seconds timeline window
        const startTime = now - windowMs;

        // Calculate Y-axis max
        let maxVal = 60;
        for (const pt of history) {
            if (pt.buffer > maxVal) maxVal = pt.buffer;
        }
        const yMax = Math.max(90, Math.ceil((maxVal * 1.15) / 30) * 30);

        const leftMargin = 32;
        const rightMargin = 10;
        const topMargin = 8;
        const bottomMargin = 16;
        const chartW = w - leftMargin - rightMargin;
        const chartH = h - topMargin - bottomMargin;

        // 1. Draw horizontal grid lines & Y labels
        const gridStep = (yMax > 150) ? 60 : 30;
        ctx.font = '9px ui-monospace, SFMono-Regular, Menlo, monospace';
        ctx.lineWidth = 1;

        for (let val = 0; val <= yMax; val += gridStep) {
            const y = topMargin + chartH - (val / yMax) * chartH;
            ctx.strokeStyle = (val === 0) ? 'rgba(255, 255, 255, 0.18)' : 'rgba(255, 255, 255, 0.07)';
            ctx.beginPath();
            ctx.moveTo(leftMargin, y);
            ctx.lineTo(w - rightMargin, y);
            ctx.stroke();

            ctx.fillStyle = 'rgba(148, 163, 184, 0.6)';
            ctx.textAlign = 'right';
            ctx.fillText(`${val}s`, leftMargin - 4, y + 3);
        }

        // 2. Draw time ticks on bottom (0s, -30s, -60s, -90s)
        ctx.fillStyle = 'rgba(148, 163, 184, 0.45)';
        ctx.textAlign = 'center';
        const timeTicks = [0, 30, 60, 90];
        for (const t of timeTicks) {
            const x = leftMargin + chartW - (t / 90) * chartW;
            const label = (t === 0) ? 'Now' : `-${t}s`;
            ctx.fillText(label, x, h - 3);
        }

        if (history.length < 2) {
            ctx.restore();
            return;
        }

        // 3. Draw streaming burst activity background bars
        for (let i = 0; i < history.length; i++) {
            const pt = history[i];
            if (pt.isStreaming) {
                const x0 = leftMargin + Math.max(0, ((pt.time - startTime) / windowMs)) * chartW;
                const nextTime = (i < history.length - 1) ? history[i + 1].time : (pt.time + 350);
                const x1 = leftMargin + Math.min(chartW, ((nextTime - startTime) / windowMs)) * chartW;
                const bandW = Math.max(2, x1 - x0);
                ctx.fillStyle = 'rgba(56, 189, 248, 0.12)';
                ctx.fillRect(x0, topMargin, bandW, chartH);
            }
        }

        // 4. Build path points
        const points = [];
        for (const pt of history) {
            if (pt.time < startTime) continue;
            const x = leftMargin + Math.max(0, Math.min(1, (pt.time - startTime) / windowMs)) * chartW;
            const clampedBuf = Math.max(0, Math.min(yMax, pt.buffer));
            const y = topMargin + chartH - (clampedBuf / yMax) * chartH;
            points.push({ x, y, buffer: pt.buffer });
        }

        if (points.length < 2) {
            ctx.restore();
            return;
        }

        // 5. Draw Area Gradient
        const gradient = ctx.createLinearGradient(0, topMargin, 0, topMargin + chartH);
        gradient.addColorStop(0, 'rgba(52, 211, 153, 0.35)'); // emerald
        gradient.addColorStop(0.6, 'rgba(56, 189, 248, 0.12)'); // cyan
        gradient.addColorStop(1, 'rgba(16, 185, 129, 0.0)');

        ctx.beginPath();
        ctx.moveTo(points[0].x, topMargin + chartH);
        for (const p of points) {
            ctx.lineTo(p.x, p.y);
        }
        ctx.lineTo(points[points.length - 1].x, topMargin + chartH);
        ctx.closePath();
        ctx.fillStyle = gradient;
        ctx.fill();

        // 6. Draw Stroke Line
        ctx.beginPath();
        ctx.moveTo(points[0].x, points[0].y);
        for (let i = 1; i < points.length; i++) {
            ctx.lineTo(points[i].x, points[i].y);
        }
        ctx.strokeStyle = '#34d399';
        ctx.lineWidth = 1.8;
        ctx.shadowColor = 'rgba(52, 211, 153, 0.5)';
        ctx.shadowBlur = 4;
        ctx.stroke();

        // Reset shadow
        ctx.shadowBlur = 0;
        ctx.shadowColor = 'transparent';

        // 7. Draw Pulse Dot at Current Head (Rightmost point)
        const lastP = points[points.length - 1];
        ctx.beginPath();
        ctx.arc(lastP.x, lastP.y, 5, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(52, 211, 153, 0.3)';
        ctx.fill();

        ctx.beginPath();
        ctx.arc(lastP.x, lastP.y, 2.5, 0, Math.PI * 2);
        ctx.fillStyle = '#ffffff';
        ctx.fill();

        ctx.restore();
    }

    // --- Metric Formatter & Telemetry Poll ---
    function updateMetrics() {
        if (!statsState.isOpen || !video) return;

        // 1. Video ID & Title
        const mediaQuery = (typeof MEDIA_QUERY !== 'undefined') ? MEDIA_QUERY : 'media';
        const mediaTitle = (typeof MEDIA_TITLE !== 'undefined' && MEDIA_TITLE) ? MEDIA_TITLE : 'Stream';
        fields.videoId.innerText = `${mediaTitle} (${mediaQuery})`;

        // 2. Viewport & Dropped Frames
        const dpr = window.devicePixelRatio || 1;
        const vpWidth = video.clientWidth || 0;
        const vpHeight = video.clientHeight || 0;
        const vpStr = `${vpWidth}x${vpHeight}*${dpr.toFixed(1)}`;

        let frameInfo = '0 dropped of 0';
        if (typeof video.getVideoPlaybackQuality === 'function') {
            const q = video.getVideoPlaybackQuality();
            const dropped = q.droppedVideoFrames || 0;
            const total = q.totalVideoFrames || 0;
            const dropPct = total > 0 ? ((dropped / total) * 100).toFixed(2) : '0.00';
            frameInfo = `${dropped} dropped of ${total} (${dropPct}%)`;
            if (q.corruptedVideoFrames) {
                frameInfo += ` [${q.corruptedVideoFrames} corrupted]`;
            }
        }
        fields.viewportFrames.innerText = `${vpStr} / ${frameInfo}`;

        // 3. Resolution
        if (video.videoWidth > 0 && video.videoHeight > 0) {
            fields.resolution.innerText = `${video.videoWidth}x${video.videoHeight}`;
        } else {
            fields.resolution.innerText = 'Connecting...';
        }

        // 4. Playback State
        let stateName = 'Idle';
        if (typeof CastController !== 'undefined' && CastController.isCasting) {
            stateName = 'Casting (Remote)';
        } else if (video.seeking) {
            stateName = 'Seeking';
        } else if (video.readyState < 3 && !video.paused) {
            stateName = 'Buffering / Waiting';
        } else if (video.paused) {
            stateName = 'Paused';
        } else {
            stateName = 'Playing';
        }
        const rate = video.playbackRate ? `${video.playbackRate.toFixed(1)}x` : '1.0x';
        fields.playState.innerText = `${stateName} @ ${rate}`;

        // 5. Volume
        const volPct = Math.round((video.volume || 0) * 100);
        fields.volume.innerText = `${volPct}% (${video.muted ? 'Muted' : 'Unmuted'})`;

        // 6. Codecs (MSE)
        const cStr = (typeof codecStr !== 'undefined') ? codecStr : 'video/mp4';
        fields.codecs.innerText = cStr;

        // 7. Original Audio Codec
        let origCodec = statsState.origAudioCodec || '';
        let activeTrk = null;
        if (typeof AUDIO_TRACKS !== 'undefined' && AUDIO_TRACKS && AUDIO_TRACKS.length > 0) {
            const curIdx = (typeof currentAudioIdx !== 'undefined') ? currentAudioIdx : -1;
            activeTrk = AUDIO_TRACKS.find(t => t.id === curIdx) || AUDIO_TRACKS[0];
            if (!origCodec && activeTrk && activeTrk.codec) {
                origCodec = activeTrk.codec;
            }
        }
        if (!origCodec) origCodec = 'AAC';
        fields.origAudioCodec.innerHTML = `<span class="stats-badge-tag stats-badge-codec">${origCodec}</span>`;

        // 8. Stream Engine
        const se = statsState.streamEngine;
        if (se.includes('native')) {
            fields.streamEngine.innerHTML = `<span class="stats-badge-tag stats-badge-native">Zero-Copy</span> ${se}`;
        } else {
            fields.streamEngine.innerHTML = `<span class="stats-badge-tag stats-badge-ffmpeg">FFmpeg</span> ${se}`;
        }

        // 9. Audio Transcoder
        const ae = statsState.audioEngine;
        if (ae.includes('native')) {
            fields.audioEngine.innerHTML = `<span class="stats-badge-tag stats-badge-native">Pure Zig</span> ${ae}`;
        } else {
            fields.audioEngine.innerHTML = `<span class="stats-badge-tag stats-badge-ffmpeg">FFmpeg</span> ${ae}`;
        }

        // 10. Active Audio Track
        if (activeTrk) {
            const codecTag = (activeTrk.codec) ? ` (${activeTrk.codec})` : '';
            fields.audioTrack.innerText = `${activeTrk.label || `Track ${activeTrk.id}`}${codecTag}`;
        } else if (typeof AUDIO_TRACKS !== 'undefined' && AUDIO_TRACKS && AUDIO_TRACKS.length > 0) {
            const curIdx = (typeof currentAudioIdx !== 'undefined') ? currentAudioIdx : -1;
            const trk = AUDIO_TRACKS.find(t => t.id === curIdx) || AUDIO_TRACKS[0];
            const codecTag = (trk.codec) ? ` (${trk.codec})` : '';
            fields.audioTrack.innerText = `${trk.label || `Track ${trk.id}`}${codecTag}`;
        } else {
            fields.audioTrack.innerText = 'Default Track';
        }

        // 11. Subtitles
        if (typeof currentSubtitleIdx !== 'undefined' && currentSubtitleIdx >= 0) {
            const curSub = (typeof SUBTITLE_TRACKS !== 'undefined' && SUBTITLE_TRACKS)
                ? SUBTITLE_TRACKS.find(t => t.id === currentSubtitleIdx)
                : null;
            const subLabel = curSub ? (curSub.label || `Track ${curSub.id}`) : `Track ${currentSubtitleIdx}`;
            const activeCuesCount = (typeof SubtitleManager !== 'undefined' && SubtitleManager.activeCues)
                ? SubtitleManager.activeCues.length
                : 0;
            fields.subtitles.innerText = `${subLabel} (${activeCuesCount} active cues)`;
        } else {
            fields.subtitles.innerText = 'Off';
        }

        // 11. Connection Speed
        const speedKbps = calculateSpeedKbps();
        if (speedKbps > 1000) {
            fields.connSpeed.innerText = `${(speedKbps / 1000).toFixed(2)} Mbps (${speedKbps.toLocaleString()} Kbps)`;
        } else if (speedKbps > 0) {
            fields.connSpeed.innerText = `${speedKbps.toLocaleString()} Kbps`;
        } else {
            fields.connSpeed.innerText = '0 Kbps (Idle)';
        }

        // 12. Network Activity
        fields.networkActivity.innerText = statsState.networkActivity;
        if (statsState.networkActivity === 'Streaming') {
            fields.networkActivity.className = 'stats-value highlight-cyan';
        } else if (statsState.networkActivity.toLowerCase().includes('buffer')) {
            fields.networkActivity.className = 'stats-value highlight-green';
        } else {
            fields.networkActivity.className = 'stats-value';
        }

        // 13. Buffer Health & Meter
        const forwardBuffer = recordBufferSample();

        fields.bufferSec.innerText = `${forwardBuffer.toFixed(2)} s`;
        const bufferTarget = 180.0; // 180 seconds target forward buffer
        const fillPct = Math.min(100, Math.max(0, (forwardBuffer / bufferTarget) * 100));
        fields.bufferFill.style.width = `${fillPct}%`;

        if (forwardBuffer >= 30) {
            fields.bufferFill.style.background = 'linear-gradient(90deg, #10b981, #34d399)';
            fields.bufferSec.className = 'highlight-green';
        } else if (forwardBuffer >= 10) {
            fields.bufferFill.style.background = 'linear-gradient(90deg, #06b6d4, #38bdf8)';
            fields.bufferSec.className = 'highlight-cyan';
        } else if (forwardBuffer >= 3) {
            fields.bufferFill.style.background = 'linear-gradient(90deg, #f59e0b, #fbbf24)';
            fields.bufferSec.className = 'highlight-amber';
        } else {
            fields.bufferFill.style.background = 'linear-gradient(90deg, #ef4444, #f87171)';
            fields.bufferSec.className = 'highlight-rose';
        }

        // 14. Total Transferred
        const transferredMb = (statsState.totalBytesDownloaded / (1024 * 1024)).toFixed(2);
        fields.transferred.innerText = `${transferredMb} MB`;

        // 15. Realtime Buffer Timeline Chart
        renderBufferChart();
    }

    // --- SysadminStats Controller ---
    const SysadminStats = {
        get isOpen() {
            return statsState.isOpen;
        },

        open() {
            createStatsPanel();
            panelEl.classList.remove('hidden');
            statsState.isOpen = true;
            updateMetrics();

            if (statsState.timerId) clearInterval(statsState.timerId);
            statsState.timerId = setInterval(updateMetrics, 250);
        },

        close() {
            if (!panelEl) return;
            panelEl.classList.add('hidden');
            statsState.isOpen = false;

            if (statsState.timerId) {
                clearInterval(statsState.timerId);
                statsState.timerId = null;
            }
        },

        toggle() {
            if (statsState.isOpen) {
                this.close();
            } else {
                this.open();
            }
        },
    };

    // Keyboard bindings: 'd' or 'D' toggles, 'Escape' closes
    document.addEventListener('keydown', (e) => {
        if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) {
            return;
        }

        if (e.key === 'd' || e.key === 'D') {
            e.preventDefault();
            SysadminStats.toggle();
        } else if (e.key === 'Escape' && statsState.isOpen) {
            e.preventDefault();
            SysadminStats.close();
        }
    });

    window.SysadminStats = SysadminStats;
})();
