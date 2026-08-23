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
        let lastReportedPosition = -100;
        let currentSourceBuffer = null;

        function getAbsoluteTime() {
            if (video.readyState < 1) {
                return currentSeekTime;
            }
            return currentSeekTime + video.currentTime;
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
                const parts = timeStr.trim().split(':');
                let hours = 0, mins = 0, secs = 0;
                if (parts.length === 3) {
                    hours = parseFloat(parts[0]);
                    mins = parseFloat(parts[1]);
                    secs = parseFloat(parts[2]);
                } else if (parts.length === 2) {
                    mins = parseFloat(parts[0]);
                    secs = parseFloat(parts[1]);
                }
                return (hours * 3600) + (mins * 60) + secs;
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

            setTrack(trackId, explicitStart) {
                currentSubtitleIdx = trackId;

                if (trackId === -1) {
                    this.activeCues = [];
                    this.updateOverlay();
                    btnSubtitles.classList.remove('active');
                    return;
                }

                btnSubtitles.classList.add('active');
                this.activeCues = [];

                const currentPos = explicitStart !== undefined ? explicitStart : getAbsoluteTime();

                if (this.abortController) this.abortController.abort();
                this.abortController = new AbortController();

                const subUrl = `/subtitles?${MEDIA_QUERY}&track=${trackId}&start=${currentPos}`;
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

            async fetchAndAppend(sourceBuffer, startTime, signal) {
                try {
                    const audioParam = currentAudioIdx >= 0 ? `&audio=${currentAudioIdx}` : '';
                    const response = await fetch(`/stream?${MEDIA_QUERY}&start=${startTime}${audioParam}`, { signal });
                    const actualStartHeader = response.headers.get('x-actual-start-time');
                    if (actualStartHeader) {
                        currentSeekTime = parseFloat(actualStartHeader);
                        SubtitleManager.updateOverlay();
                    }
                    const reader = response.body.getReader();

                    let queue = [];
                    let isAppending = false;
                    let isQuotaExceeded = false;

                    function processQueue() {
                        if (isAppending || queue.length === 0 || signal.aborted) return;
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
                                setTimeout(processQueue, 1000);
                            } else {
                                console.error('Append error:', e);
                            }
                        }
                    }

                    sourceBuffer.addEventListener('updateend', () => {
                        isAppending = false;
                        processQueue();
                    });

                    while (!signal.aborted) {
                        if (isQuotaExceeded || queue.length > 50) {
                            await new Promise(r => setTimeout(r, 100));
                            continue;
                        }

                        if (sourceBuffer.buffered.length > 0) {
                            const end = sourceBuffer.buffered.end(sourceBuffer.buffered.length - 1);
                            if (end - video.currentTime > 120) {
                                await new Promise(r => setTimeout(r, 1000));
                                continue;
                            }
                        }

                        const { done, value } = await reader.read();
                        if (done) break;

                        queue.push(value);
                        if (!isAppending) processQueue();
                    }
                } catch (e) {
                    if (e.name !== 'AbortError') console.error('Fetch error:', e);
                }
            },

            loadVideo(startTime, retryCount) {
                currentSeekTime = startTime;
                retryCount = retryCount || 0;

                if (currentSubtitleIdx !== -1) {
                    SubtitleManager.setTrack(currentSubtitleIdx, startTime);
                }

                if (abortController) abortController.abort();
                abortController = new AbortController();
                const signal = abortController.signal;

                if (!MediaSource.isTypeSupported(codecStr)) {
                    console.error('Browser does not support codec via MSE:', codecStr);
                    return;
                }

                if (currentObjectUrl) URL.revokeObjectURL(currentObjectUrl);

                const ms = new MediaSource();
                currentObjectUrl = URL.createObjectURL(ms);

                ms.addEventListener('sourceopen', () => {
                    if (signal.aborted) return;
                    if (ms.readyState !== 'open') {
                        console.error('MediaSource readyState is', ms.readyState, '- retrying');
                        if (retryCount < 3) {
                            setTimeout(() => StreamEngine.loadVideo(startTime, retryCount + 1), 100);
                        }
                        return;
                    }
                    const sb = ms.addSourceBuffer(codecStr);
                    currentSourceBuffer = sb;
                    this.fetchAndAppend(sb, startTime, signal);
                    video.play().catch(e => console.error("Play failed:", e));
                });

                video.src = currentObjectUrl;
                playpause.innerHTML = svgPause;
            },

            detach() {
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
        function initControls() {
            video.addEventListener('play', () => {
                WatchTracker.sendEvent('start', getAbsoluteTime());
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
            });

            playpause.addEventListener('click', () => {
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
                    const relativeTime = seekTo - currentSeekTime;
                    if (relativeTime >= 0 && StreamEngine.isTimeInBuffer(relativeTime)) {
                        video.currentTime = relativeTime;
                    } else {
                        StreamEngine.loadVideo(seekTo);
                    }
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

            document.addEventListener('keydown', (e) => {
                if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

                if (e.key === 'ArrowRight' || e.key === 'ArrowLeft') {
                    e.preventDefault();
                    const delta = e.key === 'ArrowRight' ? 10 : -10;
                    const seekTo = Math.max(0, Math.min(DURATION, Math.floor(getAbsoluteTime() + delta)));
                    WatchTracker.sendEvent('seek', seekTo);

                    if (CastController.isCasting && CastController.castSession) {
                        CastController.startCastAbsoluteTime = seekTo;
                        seekfill.style.width = ((seekTo / DURATION) * 100) + '%';
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
                        const relativeTime = seekTo - currentSeekTime;
                        if (relativeTime >= 0 && StreamEngine.isTimeInBuffer(relativeTime)) {
                            video.currentTime = relativeTime;
                        } else {
                            StreamEngine.loadVideo(seekTo);
                        }
                    }
                } else if (e.key === ' ') {
                    e.preventDefault();
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

        // Auto-select Forced subtitle track if available
        if (SUBTITLE_TRACKS && SUBTITLE_TRACKS.length > 0) {
            const forcedTrack = SUBTITLE_TRACKS.find(t => (t.label && t.label.toLowerCase().includes('forced')));
            if (forcedTrack) {
                currentSubtitleIdx = forcedTrack.id;
            }
        }

        StreamEngine.loadVideo(START_POSITION);
