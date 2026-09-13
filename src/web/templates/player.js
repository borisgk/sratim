        // =========================================================================
        // Sratim Web Player Engine
        // Modular architecture: Core, Subtitles, Audio, Streaming, Casting, UI
        // =========================================================================

        // --- DOM Elements & Injected Constants ---
        const video = document.getElementById('video');
        const playpause = document.getElementById('playpause');
        const seekbar = document.getElementById('seekbar');
        const seekfill = document.getElementById('seekfill');
        const timeCurrent = document.getElementById('time-current');
        const btnFullscreen = document.getElementById('fullscreen');
        const btnCast = document.getElementById('castbtn');
        const btnStopCast = document.getElementById('stopcastbtn');
        const castingOverlay = document.getElementById('casting-overlay');
        const castingDeviceName = document.getElementById('casting-device-name');
        const castingMediaTitle = document.getElementById('casting-media-title');
        const playerWrapper = document.querySelector('.player-wrapper');
        const controls = document.getElementById('controls');
        const btnBack = document.getElementById('back-btn');
        const topBar = document.getElementById('player-top-bar');
        const playerTitle = document.getElementById('player-title');
        const btnAudio = document.getElementById('audiobtn');
        const audioMenu = document.getElementById('audio-menu');
        const btnSubtitles = document.getElementById('subtitlesbtn');
        const subtitlesMenu = document.getElementById('subtitles-menu');
        const subtitleOverlay = document.getElementById('subtitle-overlay');

        const DURATION = __DURATION__;
        const MEDIA_QUERY = '__MEDIA_QUERY__';
        const codecStr = '__CODEC_STR__';
        const AUDIO_TRACKS = __AUDIO_TRACKS_JSON__;
        const SUBTITLE_TRACKS = __SUBTITLE_TRACKS_JSON__;
        const START_POSITION = __START_POSITION__;
        const MEDIA_TITLE = '__MEDIA_TITLE__';
        const SERVER_LAN_IP = '__SERVER_LAN_IP__';
        const RETURN_URL = '__RETURN_URL__';

        const svgPlay = '<svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20"><path d="M8 5v14l11-7z"/></svg>';
        const svgPause = '<svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>';
        const svgFullscreen = '<svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20"><path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z"/></svg>';
        const svgExitFullscreen = '<svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20"><path d="M5 16h3v3h2v-5H5v2zm3-8H5v2h5V5H8v3zm6 11h2v-3h3v-2h-5v5zm2-11V5h-2v5h5V8h-3z"/></svg>';

        // --- Core State ---
        let currentSeekTime = 0;
        let currentAudioIdx = -1;
        let currentSubtitleIdx = -1;
        let abortController = null;
        let currentObjectUrl = null;
        let currentMediaSource = null;
        let currentSourceBuffer = null;
        let pendingSeekTime = null;
        let seekDebounceTimeout = null;
        let lastReportedPosition = -100;
        let streamDisconnected = false;
        let isReconnecting = false;
        let lastReconnectTime = 0;

        function getAbsoluteTime() {
            if (pendingSeekTime !== null) {
                return pendingSeekTime;
            }
            if (video.readyState < 1) {
                return currentSeekTime;
            }
            return currentSeekTime + video.currentTime;
        }

        function showFormatError(msg) {
            const overlay = document.getElementById('error-overlay');
            const msgEl = document.getElementById('error-message');
            if (msgEl && msg) msgEl.textContent = msg;
            if (overlay) overlay.classList.remove('hidden');
        }

        function hideFormatError() {
            const overlay = document.getElementById('error-overlay');
            if (overlay) overlay.classList.add('hidden');
        }

        function formatTime(seconds) {
            const m = Math.floor(seconds / 60);
            const s = Math.floor(seconds % 60);
            return m + ':' + (s < 10 ? '0' : '') + s;
        }

        // =========================================================================
        // 1. Watch Tracking & Analytics Service
        // =========================================================================
        const WatchTracker = {
            async sendEvent(eventType, position) {
                try {
                    const bodyParams = {};
                    const [k, v] = MEDIA_QUERY.split('=');
                    bodyParams[k] = parseInt(v);

                    const body = JSON.stringify({
                        ...bodyParams,
                        event: eventType,
                        position: parseFloat(position),
                        duration: parseFloat(DURATION)
                    });

                    const keepalive = (eventType === 'stop');
                    if (keepalive && navigator.sendBeacon) {
                        navigator.sendBeacon('/api/watch/event', body);
                    } else {
                        await fetch('/api/watch/event', {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: body,
                            keepalive: keepalive
                        });
                    }
                } catch (e) {
                    console.error('Error logging watch event:', e);
                }
            }
        };

        // =========================================================================
        // 2. Subtitle Manager
        // =========================================================================
        const SubtitleManager = {
            activeCues: [],
            abortController: null,

            parseVttTime(timeStr) {
                if (!timeStr) return 0;
                const clean = timeStr.trim().split(/\s+/)[0];
                const parts = clean.split(':');
                let hours = 0, mins = 0, secs = 0;
                if (parts.length === 3) {
                    hours = parseFloat(parts[0]);
                    mins = parseFloat(parts[1]);
                    secs = parseFloat(parts[2]);
                } else if (parts.length === 2) {
                    mins = parseFloat(parts[0]);
                    secs = parseFloat(parts[1]);
                }
                return (hours * 3600) + (mins * 60) + (secs || 0);
            },

            updateOverlay() {
                if (!subtitleOverlay) return;
                if (currentSubtitleIdx === -1 || !this.activeCues || this.activeCues.length === 0) {
                    subtitleOverlay.classList.add('hidden');
                    subtitleOverlay.innerText = '';
                    return;
                }

                const absTime = getAbsoluteTime();
                const active = this.activeCues.filter(c => absTime >= c.start && absTime <= c.end);

                if (active.length > 0) {
                    subtitleOverlay.innerText = active.map(c => c.text).join('\n');
                    subtitleOverlay.classList.remove('hidden');
                } else {
                    subtitleOverlay.classList.add('hidden');
                    subtitleOverlay.innerText = '';
                }
            },

            setTrack(trackId) {
                if (currentSubtitleIdx === trackId && this.activeCues && this.activeCues.length > 0) {
                    this.updateOverlay();
                    return;
                }

                currentSubtitleIdx = trackId;

                if (trackId === -1) {
                    this.activeCues = [];
                    this.updateOverlay();
                    btnSubtitles.classList.remove('active');
                    if (this.abortController) this.abortController.abort();
                    return;
                }

                btnSubtitles.classList.add('active');
                this.activeCues = [];

                if (this.abortController) this.abortController.abort();
                this.abortController = new AbortController();

                const subUrl = `/subtitles?${MEDIA_QUERY}&track=${trackId}`;
                fetch(subUrl, { signal: this.abortController.signal })
                    .then(async r => {
                        const reader = r.body.getReader();
                        const decoder = new TextDecoder("utf-8");
                        let buffer = "";
                        while (true) {
                            const { done, value } = await reader.read();
                            if (value) {
                                buffer += decoder.decode(value, { stream: true });
                                const blocks = buffer.split(/\r?\n\r?\n/);
                                buffer = blocks.pop();

                                for (const block of blocks) {
                                    const lines = block.trim().split(/\r?\n/);
                                    for (let i = 0; i < lines.length; i++) {
                                        if (lines[i].includes('-->')) {
                                            const times = lines[i].split('-->');
                                            const start = this.parseVttTime(times[0]);
                                            const end = this.parseVttTime(times[1]);
                                            const text = lines.slice(i + 1).join('\n').trim();
                                            if (text) {
                                                this.activeCues.push({ start, end, text });
                                            }
                                            break;
                                        }
                                    }
                                }
                                this.updateOverlay();
                            }
                            if (done) break;
                        }
                    })
                    .catch(e => {
                        if (e.name !== 'AbortError') console.error("Subtitle fetch error:", e);
                    });
            },

            initUI() {
                btnSubtitles.style.display = 'flex';

                if (SUBTITLE_TRACKS && SUBTITLE_TRACKS.length > 0) {
                    const offBtn = document.createElement('button');
                    offBtn.className = 'sub-track-btn active';
                    offBtn.innerText = 'Off';
                    offBtn.onclick = () => {
                        this.setTrack(-1);
                        subtitlesMenu.classList.add('hidden');
                        document.querySelectorAll('.sub-track-btn').forEach(b => b.classList.remove('active'));
                        offBtn.classList.add('active');
                    };
                    subtitlesMenu.appendChild(offBtn);

                    SUBTITLE_TRACKS.forEach((track) => {
                        const btn = document.createElement('button');
                        btn.className = 'sub-track-btn';

                        let btnText = track.label || `Subtitle ${track.id}`;
                        if (track.language && track.language !== 'und' && track.label !== track.language) {
                            btnText = `[${track.language.toUpperCase()}] ${btnText}`;
                        }
                        btn.innerText = btnText;

                        btn.onclick = () => {
                            this.setTrack(track.id);
                            subtitlesMenu.classList.add('hidden');
                            document.querySelectorAll('.sub-track-btn').forEach(b => b.classList.remove('active'));
                            btn.classList.add('active');
                        };
                        subtitlesMenu.appendChild(btn);
                    });
                } else {
                    const noSubBtn = document.createElement('button');
                    noSubBtn.className = 'sub-track-btn';
                    noSubBtn.style.opacity = '0.5';
                    noSubBtn.style.cursor = 'default';
                    noSubBtn.innerText = 'No subtitles found';
                    subtitlesMenu.appendChild(noSubBtn);
                }

                btnSubtitles.addEventListener('click', (e) => {
                    e.stopPropagation();
                    if (typeof audioMenu !== 'undefined') audioMenu.classList.add('hidden');
                    subtitlesMenu.classList.toggle('hidden');
                });

                document.addEventListener('click', (e) => {
                    if (!subtitlesMenu.contains(e.target) && e.target !== btnSubtitles) {
                        subtitlesMenu.classList.add('hidden');
                    }
                });
            }
        };

        // =========================================================================
        // 3. Audio Track Manager
        // =========================================================================
        const AudioManager = {
            initUI() {
                if (!AUDIO_TRACKS || AUDIO_TRACKS.length <= 1) return;

                btnAudio.style.display = 'flex';
                AUDIO_TRACKS.forEach((track, i) => {
                    const btn = document.createElement('button');
                    btn.className = 'audio-track-btn';
                    btn.innerText = track.label || `Track ${track.id}`;
                    if (i === 0) btn.classList.add('active');

                    btn.onclick = () => {
                        if (currentAudioIdx === track.id) return;
                        currentAudioIdx = track.id;
                        audioMenu.classList.add('hidden');
                        document.querySelectorAll('.audio-track-btn').forEach(b => b.classList.remove('active'));
                        btn.classList.add('active');

                        if (CastController.isCasting && CastController.castSession) {
                            CastController.switchAudio();
                        } else {
                            StreamEngine.loadVideo(getAbsoluteTime());
                        }
                    };
                    audioMenu.appendChild(btn);
                });

                btnAudio.addEventListener('click', (e) => {
                    e.stopPropagation();
                    if (typeof subtitlesMenu !== 'undefined') subtitlesMenu.classList.add('hidden');
                    audioMenu.classList.toggle('hidden');
                });

                document.addEventListener('click', (e) => {
                    if (!audioMenu.contains(e.target) && e.target !== btnAudio) {
                        audioMenu.classList.add('hidden');
                    }
                });
            }
        };

        // =========================================================================
        // 4. Stream Engine (MSE & Backpressure Buffer Management)
        // =========================================================================
        const StreamEngine = {
            isTimeInBuffer(relativeTime) {
                if (!currentSourceBuffer || relativeTime < 0) return false;
                try {
                    for (let i = 0; i < currentSourceBuffer.buffered.length; i++) {
                        if (relativeTime >= currentSourceBuffer.buffered.start(i) &&
                            relativeTime <= currentSourceBuffer.buffered.end(i)) {
                            return true;
                        }
                    }
                } catch (e) {}
                return false;
            },

            seek(targetTime) {
                if (seekDebounceTimeout) {
                    clearTimeout(seekDebounceTimeout);
                    seekDebounceTimeout = null;
                }
                pendingSeekTime = targetTime;
                const relativeTime = targetTime - currentSeekTime;
                if (relativeTime >= 0 && this.isTimeInBuffer(relativeTime)) {
                    video.currentTime = relativeTime;
                    pendingSeekTime = null;
                } else {
                    this.loadVideo(targetTime);
                }
            },

            seekDebounced(targetTime) {
                if (seekDebounceTimeout) {
                    clearTimeout(seekDebounceTimeout);
                }
                const relativeTime = targetTime - currentSeekTime;
                if (relativeTime >= 0 && this.isTimeInBuffer(relativeTime)) {
                    video.currentTime = relativeTime;
                    pendingSeekTime = null;
                    return;
                }
                seekDebounceTimeout = setTimeout(() => {
                    seekDebounceTimeout = null;
                    this.loadVideo(targetTime);
                }, 150);
            },

            async fetchAndAppend(sourceBuffer, startTime, signal, autoPlay = true) {
                let onUpdateEnd = null;
                try {
                    const audioParam = currentAudioIdx >= 0 ? `&audio=${currentAudioIdx}` : '';
                    const response = await fetch(`/stream?${MEDIA_QUERY}&start=${startTime}${audioParam}`, { signal });
                    if (!response.ok) {
                        if (response.status === 502 || response.status === 503 || response.status === 504) {
                            console.warn(`Gateway error ${response.status} from proxy. Scheduling auto-reconnect.`);
                            streamDisconnected = true;
                            return;
                        }
                        const errMsg = await response.text();
                        showFormatError(errMsg || 'This media format is not supported for native playback.');
                        return;
                    }
                    if (window.__onStreamResponse) {
                        window.__onStreamResponse(response);
                    }
                    const actualStartHeader = response.headers.get('x-actual-start-time');
                    if (actualStartHeader) {
                        currentSeekTime = parseFloat(actualStartHeader);
                        SubtitleManager.updateOverlay();
                    }
                    const reader = response.body.getReader();

                    let queue = [];
                    let isAppending = false;
                    let hasInitializedPlayback = false;
                    let isQuotaExceeded = false;
                    let maxCapacity = 210; // Upper capacity ceiling in seconds
                    let isRefilling = true;
                    let lastRefillEndTime = Date.now();
                    let bufferAtRefillEnd = 0;
                    window.__bufferTarget = maxCapacity;

                    let isEvicting = false;
                    function evictOldBuffer(aggressive = false) {
                        if (isEvicting || !sourceBuffer || sourceBuffer.updating || isAppending || sourceBuffer.buffered.length === 0) return;
                        const retainPast = aggressive ? 10 : 30;
                        const evictUpTo = video.currentTime - retainPast;
                        if (evictUpTo > 5 && sourceBuffer.buffered.start(0) < evictUpTo - 5) {
                            isEvicting = true;
                            try {
                                sourceBuffer.remove(0, evictUpTo);
                            } catch (e) {
                                isEvicting = false;
                            }
                        }
                    }

                    function processQueue() {
                        if (isAppending || queue.length === 0 || signal.aborted || sourceBuffer.updating) return;
                        isAppending = true;

                        let totalLen = 0;
                        for (let q of queue) totalLen += q.length;
                        let combined = new Uint8Array(totalLen);
                        let offset = 0;
                        for (let q of queue) {
                            combined.set(q, offset);
                            offset += q.length;
                        }
                        queue = [];

                        try {
                            sourceBuffer.appendBuffer(combined);
                            isQuotaExceeded = false;
                        } catch (e) {
                            if (e.name === 'QuotaExceededError') {
                                queue.unshift(combined);
                                isAppending = false;
                                isQuotaExceeded = true;
                                evictOldBuffer(true);
                                if (sourceBuffer.buffered.length > 0) {
                                    const currentAhead = sourceBuffer.buffered.end(sourceBuffer.buffered.length - 1) - video.currentTime;
                                    // Adapt capacity to actual device quota limit
                                    maxCapacity = Math.max(25, Math.floor(currentAhead - 2));
                                    window.__bufferTarget = maxCapacity;
                                    bufferAtRefillEnd = currentAhead;
                                    isRefilling = false;
                                    lastRefillEndTime = Date.now();
                                    if (window.__onStreamState) window.__onStreamState('Paced');
                                }
                                setTimeout(processQueue, 500);
                            } else {
                                isAppending = false;
                                console.error('Append error:', e);
                            }
                        }
                    }

                    onUpdateEnd = () => {
                        isAppending = false;
                        if (isEvicting) {
                            isEvicting = false;
                            processQueue();
                            return;
                        }
                        if (!hasInitializedPlayback && sourceBuffer.buffered.length > 0) {
                            hasInitializedPlayback = true;
                            video.currentTime = 0;
                            pendingSeekTime = null;
                            if (autoPlay) {
                                video.play().catch(e => console.error("Play failed:", e));
                            } else {
                                video.pause();
                                playpause.innerHTML = svgPlay;
                            }
                        }
                        evictOldBuffer(false);
                        processQueue();

                        // When reading is paused and all queued chunks are appended into MSE, top-up is complete
                        if (!isRefilling && queue.length === 0 && !isAppending && sourceBuffer.buffered.length > 0) {
                            const end = sourceBuffer.buffered.end(sourceBuffer.buffered.length - 1);
                            bufferAtRefillEnd = end - video.currentTime;
                            lastRefillEndTime = Date.now();
                            if (window.__onStreamState) {
                                window.__onStreamState('Paced');
                            }
                        }
                    };
                    sourceBuffer.addEventListener('updateend', onUpdateEnd);

                    while (!signal.aborted) {
                        // Double-buffering: throttle pre-reading to max 2 chunks while MSE is appending
                        if (isQuotaExceeded || queue.length >= 2) {
                            await new Promise(r => setTimeout(r, 20));
                            continue;
                        }

                        if (sourceBuffer.buffered.length > 0) {
                            const end = sourceBuffer.buffered.end(sourceBuffer.buffered.length - 1);
                            const bufferAhead = end - video.currentTime;

                            if (isRefilling) {
                                // Stop fetching once buffer reaches capacity
                                if (bufferAhead >= maxCapacity) {
                                    isRefilling = false;
                                    if (queue.length === 0 && !isAppending && (!sourceBuffer || !sourceBuffer.updating)) {
                                        bufferAtRefillEnd = bufferAhead;
                                        lastRefillEndTime = Date.now();
                                        if (window.__onStreamState) {
                                            window.__onStreamState('Paced');
                                        }
                                    }
                                }
                            } else {
                                const timeSinceRefill = Date.now() - lastRefillEndTime;
                                const bufferConsumed = bufferAtRefillEnd - bufferAhead;
                                const isBufferFullAndPaused = video.paused && bufferAhead >= (maxCapacity - 3);

                                // Refill trigger (when not paused with full buffer):
                                // 1. Exactly 15s elapsed since last refill
                                // 2. Rapid consumption: buffer consumed >= 15s (e.g. 2x playback speed)
                                // 3. Safety floor: buffer dropped to <= 15s
                                if (!isBufferFullAndPaused && (timeSinceRefill >= 15000 || bufferConsumed >= 15 || bufferAhead <= 15)) {
                                    isRefilling = true;
                                    if (window.__onStreamState) {
                                        window.__onStreamState('Streaming');
                                    }
                                }
                            }

                            if (!isRefilling) {
                                await new Promise(r => setTimeout(r, 200));
                                continue;
                            }
                        }

                        const { done, value } = await reader.read();
                        if (done) {
                            const currentPos = currentSeekTime + (video.currentTime || 0);
                            const isPremature = !signal.aborted && (DURATION <= 0 || (currentPos < DURATION - 5));
                            if (isPremature) {
                                console.warn(`Stream connection closed prematurely at ${currentPos.toFixed(1)}s (total ${DURATION}s). Marked for auto-reconnect.`);
                                streamDisconnected = true;
                            }
                            break;
                        }

                        if (window.__onStreamChunk && value) {
                            window.__onStreamChunk(value.byteLength);
                        }

                        queue.push(value);
                        if (!isAppending) processQueue();
                    }
                    if (window.__onStreamState) window.__onStreamState('Idle');
                } catch (e) {
                    if (e.name !== 'AbortError') {
                        console.error('Fetch error:', e);
                        const currentPos = currentSeekTime + (video.currentTime || 0);
                        const isPremature = !signal.aborted && (DURATION <= 0 || (currentPos < DURATION - 5));
                        if (isPremature) {
                            console.warn(`Stream connection lost at ${currentPos.toFixed(1)}s due to network error. Marked for auto-reconnect.`);
                            streamDisconnected = true;
                        }
                    }
                } finally {
                    if (onUpdateEnd) {
                        try {
                            sourceBuffer.removeEventListener('updateend', onUpdateEnd);
                        } catch (e) {}
                    }
                }
            },

            attemptReconnect() {
                if (isReconnecting || (abortController && abortController.signal.aborted)) return;
                const now = Date.now();
                if (now - lastReconnectTime < 2500) return;
                lastReconnectTime = now;

                const absTime = getAbsoluteTime();
                if (DURATION > 0 && absTime >= DURATION - 5) {
                    streamDisconnected = false;
                    return;
                }

                console.log(`StreamEngine: Auto-reconnecting stream from ${absTime.toFixed(1)}s`);
                isReconnecting = true;
                streamDisconnected = false;
                const wasPlaying = !video.paused;
                this.loadVideo(absTime, 0, wasPlaying);
            },

            loadVideo(startTime, retryCount, autoPlay = true) {
                hideFormatError();
                streamDisconnected = false;
                isReconnecting = false;
                if (seekDebounceTimeout) {
                    clearTimeout(seekDebounceTimeout);
                    seekDebounceTimeout = null;
                }
                pendingSeekTime = startTime;
                retryCount = retryCount || 0;

                if (currentSubtitleIdx !== -1) {
                    SubtitleManager.updateOverlay();
                }

                if (abortController) abortController.abort();
                abortController = new AbortController();
                const signal = abortController.signal;

                // Reuse existing open MediaSource to prevent tearing down the audio device / decoder context
                if (currentMediaSource && currentMediaSource.readyState === 'open' && currentSourceBuffer) {
                    const doSeek = () => {
                        video.pause();
                        try {
                            currentSourceBuffer.abort();
                        } catch (e) {}

                        const startNewStream = () => {
                            currentSeekTime = startTime;
                            this.fetchAndAppend(currentSourceBuffer, startTime, signal, autoPlay);
                        };

                        if (currentSourceBuffer.buffered.length > 0) {
                            const onRemoved = () => {
                                currentSourceBuffer.removeEventListener('updateend', onRemoved);
                                startNewStream();
                            };
                            currentSourceBuffer.addEventListener('updateend', onRemoved);
                            try {
                                currentSourceBuffer.remove(0, 1000000);
                            } catch (e) {
                                currentSourceBuffer.removeEventListener('updateend', onRemoved);
                                startNewStream();
                            }
                        } else {
                            startNewStream();
                        }
                    };

                    if (currentSourceBuffer.updating) {
                        const onEnd = () => {
                            currentSourceBuffer.removeEventListener('updateend', onEnd);
                            doSeek();
                        };
                        currentSourceBuffer.addEventListener('updateend', onEnd);
                    } else {
                        doSeek();
                    }
                    if (autoPlay) {
                        playpause.innerHTML = svgPause;
                    }
                    return;
                }

                if (!MediaSource.isTypeSupported(codecStr)) {
                    console.error('Browser does not support codec via MSE:', codecStr);
                    return;
                }

                if (currentObjectUrl) URL.revokeObjectURL(currentObjectUrl);

                const ms = new MediaSource();
                currentMediaSource = ms;
                currentObjectUrl = URL.createObjectURL(ms);

                ms.addEventListener('sourceopen', () => {
                    if (signal.aborted) return;
                    if (ms.readyState !== 'open') {
                        console.error('MediaSource readyState is', ms.readyState, '- retrying');
                        if (retryCount < 3) {
                            setTimeout(() => StreamEngine.loadVideo(startTime, retryCount + 1, autoPlay), 100);
                        }
                        return;
                    }
                    const sb = ms.addSourceBuffer(codecStr);
                    currentSourceBuffer = sb;
                    currentSeekTime = startTime;
                    this.fetchAndAppend(sb, startTime, signal, autoPlay);
                });

                video.src = currentObjectUrl;
                if (autoPlay) {
                    playpause.innerHTML = svgPause;
                }
            },

            detach() {
                streamDisconnected = false;
                isReconnecting = false;
                if (seekDebounceTimeout) {
                    clearTimeout(seekDebounceTimeout);
                    seekDebounceTimeout = null;
                }
                pendingSeekTime = null;
                video.pause();
                video.src = '';
                video.removeAttribute('src');
                video.load();
                if (currentObjectUrl) {
                    URL.revokeObjectURL(currentObjectUrl);
                    currentObjectUrl = null;
                }
                if (abortController) {
                    abortController.abort();
                    abortController = null;
                }
                currentMediaSource = null;
                currentSourceBuffer = null;
            }
        };

        // =========================================================================
        // 5. Cast Receiver & Session Controller
        // =========================================================================
        const CastController = {
            isCasting: false,
            castSession: null,
            remotePlayer: null,
            remotePlayerController: null,
            startCastAbsoluteTime: 0,
            disconnectHandled: false,

            getPosition() {
                if (this.isCasting && this.remotePlayer && typeof this.remotePlayer.currentTime === 'number') {
                    return this.startCastAbsoluteTime + this.remotePlayer.currentTime;
                }
                return getAbsoluteTime();
            },

            getStreamUrl(castPosition) {
                let host = window.location.origin;
                if (window.location.hostname === 'localhost' || window.location.hostname === '127.0.0.1') {
                    if (SERVER_LAN_IP && SERVER_LAN_IP.length > 0) {
                        const portStr = window.location.port ? (':' + window.location.port) : '';
                        host = 'http://' + SERVER_LAN_IP + portStr;
                    } else {
                        let savedIp = localStorage.getItem('sratim_cast_ip');
                        if (!savedIp) {
                            savedIp = prompt('Casting from localhost requires your PC\'s local IP address on your Wi-Fi network (e.g. 192.168.1.100):', '');
                            if (savedIp) {
                                localStorage.setItem('sratim_cast_ip', savedIp.trim());
                            }
                        }
                        if (savedIp) {
                            const portStr = window.location.port ? (':' + window.location.port) : '';
                            host = 'http://' + savedIp.trim() + portStr;
                        }
                    }
                }
                let url = host + '/stream?' + MEDIA_QUERY + '&start=' + Math.floor(castPosition);
                if (currentAudioIdx >= 0) {
                    url += '&audio=' + currentAudioIdx;
                }
                return url;
            },

            switchAudio() {
                const resumeTime = this.getPosition();
                this.startCastAbsoluteTime = resumeTime;
                const mediaUrl = this.getStreamUrl(resumeTime);
                const mediaInfo = new chrome.cast.media.MediaInfo(mediaUrl, 'video/mp4');
                mediaInfo.streamType = chrome.cast.media.StreamType.BUFFERED;
                mediaInfo.duration = DURATION;
                mediaInfo.metadata = new chrome.cast.media.GenericMediaMetadata();
                mediaInfo.metadata.title = MEDIA_TITLE;
                const request = new chrome.cast.media.LoadRequest(mediaInfo);
                request.currentTime = 0;
                this.castSession.loadMedia(request).catch(e => console.error("Cast audio switch failed:", e));
            },

            async start() {
                const castPosition = getAbsoluteTime();
                this.startCastAbsoluteTime = castPosition;

                if (window.cast && window.cast.framework) {
                    const castContext = cast.framework.CastContext.getInstance();
                    try {
                        await castContext.requestSession();
                        this.castSession = castContext.getCurrentSession();

                        const deviceName = (this.castSession.getCastDevice() && this.castSession.getCastDevice().friendlyName) || 'TV Device';
                        castingDeviceName.innerText = deviceName;
                        castingMediaTitle.innerText = MEDIA_TITLE;

                        const mediaUrl = this.getStreamUrl(castPosition);
                        const mediaInfo = new chrome.cast.media.MediaInfo(mediaUrl, 'video/mp4');
                        mediaInfo.streamType = chrome.cast.media.StreamType.BUFFERED;
                        mediaInfo.duration = DURATION;
                        mediaInfo.metadata = new chrome.cast.media.GenericMediaMetadata();
                        mediaInfo.metadata.title = MEDIA_TITLE;

                        const request = new chrome.cast.media.LoadRequest(mediaInfo);
                        request.currentTime = 0;
                        await this.castSession.loadMedia(request);

                        this.onConnected();
                        WatchTracker.sendEvent('start', castPosition);
                    } catch (e) {
                        console.error('Google Cast failed or cancelled:', e);
                        if (video.remote && typeof video.remote.prompt === 'function') {
                            video.remote.prompt().catch(err => console.log('Remote playback prompt cancelled:', err));
                        }
                    }
                } else if (video.remote && typeof video.remote.prompt === 'function') {
                    video.remote.prompt().catch(err => console.log('Remote playback prompt cancelled:', err));
                } else {
                    alert('Casting is not supported on this browser/device. Make sure you are using Chrome or Edge on the same Wi-Fi network as your TV.');
                }
            },

            stop() {
                const lastCastTime = this.getPosition();
                this.disconnectHandled = true;
                if (window.cast && window.cast.framework) {
                    const castContext = cast.framework.CastContext.getInstance();
                    castContext.endCurrentSession(true);
                }
                this.onDisconnected(lastCastTime);
                setTimeout(() => { this.disconnectHandled = false; }, 500);
            },

            onConnected() {
                this.isCasting = true;
                this.disconnectHandled = false;
                StreamEngine.detach();
                btnCast.classList.add('active');
                castingOverlay.classList.remove('hidden');
            },

            onDisconnected(resumeTime) {
                this.isCasting = false;
                btnCast.classList.remove('active');
                castingOverlay.classList.add('hidden');
                const targetTime = (typeof resumeTime === 'number') ? resumeTime : this.getPosition();
                StreamEngine.loadVideo(targetTime);
            },

            init() {
                btnCast.addEventListener('click', () => {
                    if (this.isCasting) {
                        this.stop();
                    } else {
                        this.start();
                    }
                });

                btnStopCast.addEventListener('click', () => this.stop());

                window.__onGCastApiAvailable = (isAvailable) => {
                    if (isAvailable && window.cast && window.cast.framework) {
                        const castContext = cast.framework.CastContext.getInstance();
                        castContext.setOptions({
                            receiverApplicationId: chrome.cast.media.DEFAULT_MEDIA_RECEIVER_APP_ID,
                            autoJoinPolicy: chrome.cast.AutoJoinPolicy.ORIGIN_SCOPED
                        });

                        this.remotePlayer = new cast.framework.RemotePlayer();
                        this.remotePlayerController = new cast.framework.RemotePlayerController(this.remotePlayer);

                        this.remotePlayerController.addEventListener(
                            cast.framework.RemotePlayerEventType.IS_CONNECTED_CHANGED,
                            () => {
                                if (this.remotePlayer.isConnected) {
                                    this.onConnected();
                                } else if (!this.disconnectHandled) {
                                    this.onDisconnected();
                                }
                            }
                        );

                        this.remotePlayerController.addEventListener(
                            cast.framework.RemotePlayerEventType.CURRENT_TIME_CHANGED,
                            () => {
                                if (this.isCasting && typeof this.remotePlayer.currentTime === 'number') {
                                    const actualTime = this.startCastAbsoluteTime + this.remotePlayer.currentTime;
                                    const percentage = (actualTime / DURATION) * 100;
                                    seekfill.style.width = percentage + '%';
                                    timeCurrent.innerText = formatTime(actualTime);
                                    if (Math.abs(actualTime - lastReportedPosition) >= 10) {
                                        lastReportedPosition = actualTime;
                                        WatchTracker.sendEvent('progress', actualTime);
                                    }
                                }
                            }
                        );

                        this.remotePlayerController.addEventListener(
                            cast.framework.RemotePlayerEventType.IS_PAUSED_CHANGED,
                            () => {
                                if (this.isCasting) {
                                    playpause.innerHTML = this.remotePlayer.isPaused ? svgPlay : svgPause;
                                }
                            }
                        );
                    }
                };
            }
        };

        // =========================================================================
        // 6. UI Controls & Keyboard Shortcuts
        // =========================================================================
        function updateVideoLayout() {
            if (!video || !playerWrapper) return;
            const vw = video.videoWidth;
            const vh = video.videoHeight;
            if (!vw || !vh) {
                video.style.width = '100%';
                video.style.height = '100%';
                video.style.left = '0px';
                video.style.top = '0px';
                return;
            }
            const cw = playerWrapper.clientWidth;
            const ch = playerWrapper.clientHeight;
            if (!cw || !ch) return;

            const videoRatio = vw / vh;
            const containerRatio = cw / ch;

            let targetW, targetH;
            if (containerRatio > videoRatio) {
                // Limited by container height
                targetH = ch;
                targetW = Math.round(targetH * videoRatio);
            } else {
                // Limited by container width
                targetW = cw;
                targetH = Math.round(targetW / videoRatio);
            }

            const left = Math.round((cw - targetW) / 2);
            const top = Math.round((ch - targetH) / 2);

            video.style.width = targetW + 'px';
            video.style.height = targetH + 'px';
            video.style.left = left + 'px';
            video.style.top = top + 'px';
        }

        function initControls() {
            function togglePlayPause() {
                if (CastController.isCasting && CastController.remotePlayerController) {
                    CastController.remotePlayerController.playOrPause();
                } else {
                    if (video.paused) {
                        video.play();
                        playpause.innerHTML = svgPause;
                    } else {
                        video.pause();
                        playpause.innerHTML = svgPlay;
                    }
                }
            }

            video.addEventListener('play', () => {
                playpause.innerHTML = svgPause;
                WatchTracker.sendEvent('start', getAbsoluteTime());
                if (streamDisconnected) {
                    const remainingBuffer = (currentSourceBuffer && currentSourceBuffer.buffered.length > 0)
                        ? (currentSourceBuffer.buffered.end(currentSourceBuffer.buffered.length - 1) - video.currentTime)
                        : 0;
                    if (remainingBuffer <= 10) {
                        StreamEngine.attemptReconnect();
                    }
                }
            });

            video.addEventListener('pause', () => {
                playpause.innerHTML = svgPlay;
            });

            const handleStreamStall = () => {
                if (streamDisconnected && !isReconnecting) {
                    StreamEngine.attemptReconnect();
                } else if (!isReconnecting && currentSourceBuffer) {
                    const remaining = (currentSourceBuffer.buffered.length > 0)
                        ? (currentSourceBuffer.buffered.end(currentSourceBuffer.buffered.length - 1) - video.currentTime)
                        : 0;
                    if (remaining <= 0.5) {
                        const absTime = getAbsoluteTime();
                        if (DURATION <= 0 || absTime < DURATION - 5) {
                            StreamEngine.attemptReconnect();
                        }
                    }
                }
            };
            video.addEventListener('waiting', handleStreamStall);
            video.addEventListener('stalled', handleStreamStall);

            setInterval(() => {
                if (streamDisconnected && !isReconnecting && !video.paused) {
                    const remainingBuffer = (currentSourceBuffer && currentSourceBuffer.buffered.length > 0)
                        ? (currentSourceBuffer.buffered.end(currentSourceBuffer.buffered.length - 1) - video.currentTime)
                        : 0;
                    if (remainingBuffer <= 4 || video.readyState < 3) {
                        StreamEngine.attemptReconnect();
                    }
                }
            }, 2000);

            video.addEventListener('loadedmetadata', updateVideoLayout);
            video.addEventListener('resize', updateVideoLayout);
            window.addEventListener('resize', updateVideoLayout);
            document.addEventListener('fullscreenchange', () => {
                setTimeout(updateVideoLayout, 50);
            });
            if (window.ResizeObserver) {
                const ro = new ResizeObserver(() => {
                    updateVideoLayout();
                });
                ro.observe(playerWrapper);
            }

            video.addEventListener('seeked', () => {
                SubtitleManager.updateOverlay();
            });

            video.addEventListener('timeupdate', () => {
                const actualTime = getAbsoluteTime();
                const percentage = (actualTime / DURATION) * 100;
                seekfill.style.width = percentage + '%';
                timeCurrent.innerText = formatTime(actualTime);
                SubtitleManager.updateOverlay();

                if (Math.abs(actualTime - lastReportedPosition) >= 10) {
                    lastReportedPosition = actualTime;
                    WatchTracker.sendEvent('progress', actualTime);
                }

                if (streamDisconnected && !isReconnecting) {
                    const remainingBuffer = (currentSourceBuffer && currentSourceBuffer.buffered.length > 0)
                        ? (currentSourceBuffer.buffered.end(currentSourceBuffer.buffered.length - 1) - video.currentTime)
                        : 0;
                    if (remainingBuffer <= 4) {
                        StreamEngine.attemptReconnect();
                    }
                }
            });

            playpause.addEventListener('click', (e) => {
                e.stopPropagation();
                togglePlayPause();
            });

            seekbar.addEventListener('click', (e) => {
                const rect = seekbar.getBoundingClientRect();
                const percentage = (e.clientX - rect.left) / rect.width;
                const seekTo = Math.max(0, Math.floor(percentage * DURATION));
                WatchTracker.sendEvent('seek', seekTo);

                if (CastController.isCasting && CastController.castSession) {
                    CastController.startCastAbsoluteTime = seekTo;
                    seekfill.style.width = (percentage * 100) + '%';
                    timeCurrent.innerText = formatTime(seekTo);
                    const mediaUrl = CastController.getStreamUrl(seekTo);
                    const mediaInfo = new chrome.cast.media.MediaInfo(mediaUrl, 'video/mp4');
                    mediaInfo.streamType = chrome.cast.media.StreamType.BUFFERED;
                    mediaInfo.duration = DURATION;
                    mediaInfo.metadata = new chrome.cast.media.GenericMediaMetadata();
                    mediaInfo.metadata.title = MEDIA_TITLE;
                    const request = new chrome.cast.media.LoadRequest(mediaInfo);
                    request.currentTime = 0;
                    CastController.castSession.loadMedia(request).catch(err => console.error("Cast seek failed:", err));
                } else {
                    seekfill.style.width = (percentage * 100) + '%';
                    timeCurrent.innerText = formatTime(seekTo);
                    StreamEngine.seek(seekTo);
                }
            });

            btnFullscreen.addEventListener('click', () => {
                if (!document.fullscreenElement) {
                    playerWrapper.requestFullscreen().catch(err => console.error(err));
                } else {
                    document.exitFullscreen();
                }
            });

            document.addEventListener('fullscreenchange', () => {
                if (document.fullscreenElement) {
                    btnFullscreen.innerHTML = svgExitFullscreen;
                } else {
                    btnFullscreen.innerHTML = svgFullscreen;
                }
            });

            function handleBack() {
                WatchTracker.sendEvent('stop', getAbsoluteTime());
                if (document.fullscreenElement) {
                    document.exitFullscreen().catch(() => {});
                }
                if (RETURN_URL && RETURN_URL !== '/' && RETURN_URL !== '') {
                    window.location.href = RETURN_URL;
                } else if (document.referrer && document.referrer.includes(window.location.host) && !document.referrer.includes('/player')) {
                    window.location.href = document.referrer;
                } else {
                    window.location.href = RETURN_URL || '/';
                }
            }

            if (btnBack) {
                btnBack.addEventListener('click', (e) => {
                    e.stopPropagation();
                    handleBack();
                });
            }

            // Inactivity & auto-hide handling
            let inactivityTimeout = null;
            function resetInactivityTimer() {
                if (topBar) topBar.classList.remove('inactive');
                if (controls) controls.classList.remove('inactive');
                playerWrapper.classList.remove('hide-cursor');
                if (inactivityTimeout) {
                    clearTimeout(inactivityTimeout);
                    inactivityTimeout = null;
                }
                if (!video.paused && !CastController.isCasting) {
                    inactivityTimeout = setTimeout(() => {
                        if (!audioMenu.classList.contains('hidden') || !subtitlesMenu.classList.contains('hidden')) {
                            return;
                        }
                        if (topBar) topBar.classList.add('inactive');
                        if (controls) controls.classList.add('inactive');
                        playerWrapper.classList.add('hide-cursor');
                    }, 3000);
                }
            }

            playerWrapper.addEventListener('mousemove', resetInactivityTimer);
            playerWrapper.addEventListener('pointerdown', resetInactivityTimer);
            if (topBar) {
                topBar.addEventListener('mouseenter', () => {
                    if (inactivityTimeout) clearTimeout(inactivityTimeout);
                });
                topBar.addEventListener('mouseleave', resetInactivityTimer);
            }
            if (controls) {
                controls.addEventListener('mouseenter', () => {
                    if (inactivityTimeout) clearTimeout(inactivityTimeout);
                });
                controls.addEventListener('mouseleave', resetInactivityTimer);
            }
            video.addEventListener('play', resetInactivityTimer);
            video.addEventListener('pause', () => {
                if (topBar) topBar.classList.remove('inactive');
                if (controls) controls.classList.remove('inactive');
                playerWrapper.classList.remove('hide-cursor');
                if (inactivityTimeout) {
                    clearTimeout(inactivityTimeout);
                    inactivityTimeout = null;
                }
            });

            playerWrapper.addEventListener('click', (e) => {
                if (e.target.closest('#controls') ||
                    e.target.closest('#player-top-bar') ||
                    e.target.closest('#audio-menu') ||
                    e.target.closest('#subtitles-menu') ||
                    e.target.closest('#casting-overlay') ||
                    e.target.closest('#error-overlay') ||
                    e.target.closest('.stats-panel')) {
                    return;
                }
                togglePlayPause();
            });

            playerWrapper.addEventListener('dblclick', (e) => {
                if (e.target.closest('#controls') ||
                    e.target.closest('#player-top-bar') ||
                    e.target.closest('#audio-menu') ||
                    e.target.closest('#subtitles-menu')) {
                    return;
                }
                e.preventDefault();
                if (!document.fullscreenElement) {
                    playerWrapper.requestFullscreen().catch(err => console.error(err));
                } else {
                    document.exitFullscreen();
                }
            });

            document.addEventListener('keydown', (e) => {
                if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

                if (e.key === 'Backspace') {
                    e.preventDefault();
                    handleBack();
                } else if (e.key === 'Escape' && !document.fullscreenElement) {
                    e.preventDefault();
                    handleBack();
                } else if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
                    e.preventDefault();
                    const delta = e.key === 'ArrowRight' ? 10 : -10;
                    const baseTime = pendingSeekTime !== null ? pendingSeekTime : getAbsoluteTime();
                    const seekTo = Math.max(0, Math.min(DURATION, Math.floor(baseTime + delta)));
                    pendingSeekTime = seekTo;
                    seekfill.style.width = ((seekTo / DURATION) * 100) + '%';
                    timeCurrent.innerText = formatTime(seekTo);
                    WatchTracker.sendEvent('seek', seekTo);

                    if (CastController.isCasting && CastController.castSession) {
                        CastController.startCastAbsoluteTime = seekTo;
                        const mediaUrl = CastController.getStreamUrl(seekTo);
                        const mediaInfo = new chrome.cast.media.MediaInfo(mediaUrl, 'video/mp4');
                        mediaInfo.streamType = chrome.cast.media.StreamType.BUFFERED;
                        mediaInfo.duration = DURATION;
                        mediaInfo.metadata = new chrome.cast.media.GenericMediaMetadata();
                        mediaInfo.metadata.title = MEDIA_TITLE;
                        const request = new chrome.cast.media.LoadRequest(mediaInfo);
                        request.currentTime = 0;
                        CastController.castSession.loadMedia(request).catch(err => console.error("Cast seek failed:", err));
                        pendingSeekTime = null;
                    } else {
                        StreamEngine.seekDebounced(seekTo);
                    }
                } else if (e.key === ' ') {
                    e.preventDefault();
                    togglePlayPause();
                } else if (e.key === 'f' || e.key === 'F') {
                    if (!document.fullscreenElement) {
                        playerWrapper.requestFullscreen().catch(err => console.error(err));
                    } else {
                        document.exitFullscreen();
                    }
                }
            });

            const handleStop = () => {
                WatchTracker.sendEvent('stop', getAbsoluteTime());
            };
            window.addEventListener('beforeunload', handleStop);
            window.addEventListener('pagehide', handleStop);
        }

        // =========================================================================
        // 7. Player Bootstrap
        // =========================================================================
        SubtitleManager.initUI();
        AudioManager.initUI();
        CastController.init();
        initControls();
        updateVideoLayout();

        // Auto-select Forced subtitle track if available
        if (SUBTITLE_TRACKS && SUBTITLE_TRACKS.length > 0) {
            const forcedTrack = SUBTITLE_TRACKS.find(t => (t.label && t.label.toLowerCase().includes('forced')));
            if (forcedTrack) {
                SubtitleManager.setTrack(forcedTrack.id);
            }
        }

        StreamEngine.loadVideo(START_POSITION);
