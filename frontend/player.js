document.addEventListener('DOMContentLoaded', async () => {
    // Basic UI Setup
    const videoElement = document.getElementById('mainVideo');
    const moviePath = sessionStorage.getItem('currentMoviePath');
    const audioSelect = document.getElementById('audioTrackSelect');
    const subtitleSelect = document.getElementById('subtitleTrackSelect');

    if (!moviePath) {
        console.error('No movie path found');
        window.location.href = 'index.html';
        return;
    }

    if (!window.MediaSource) {
        console.error('MSE not supported');
        alert('MSE not supported by browser');
        return;
    }

    // Global State
    let currentAudioTrackIndex = 0;
    let lastDecodeErrorTime = 0;
    let currentMediaSource = null;
    let currentAbortController = null;

    // Main Initialization Function
    const loadVideo = async (startPosition = 0) => {
        console.log(`Initializing player at ${startPosition}s...`);

        // 1. Cleanup previous state
        if (currentAbortController) {
            currentAbortController.abort();
            currentAbortController = null;
        }

        // 2. Create new MediaSource
        const mediaSource = new MediaSource();
        currentMediaSource = mediaSource;
        videoElement.src = URL.createObjectURL(mediaSource);

        mediaSource.addEventListener('sourceopen', async () => {
            // If this mediaSource is stale (replaced during async wait), stop.
            if (mediaSource !== currentMediaSource) {
                console.log("MediaSource replaced, stopping old initialization.");
                return;
            }

            URL.revokeObjectURL(videoElement.src); // Good practice

            try {
                // Fetch Metadata
                console.log(`Fetching metadata for: ${moviePath}`);
                const metaResponse = await fetch(`/api/metadata?path=${encodeURIComponent(moviePath)}`);
                if (!metaResponse.ok) throw new Error(`Metadata fetch failed: ${metaResponse.status}`);
                const metadata = await metaResponse.json();

                // Setup Duration
                if (metadata.duration && metadata.duration > 0) {
                    mediaSource.duration = metadata.duration;
                }

                // Setup Video Codec
                let videoCodec = 'avc1.4d4028';
                if (metadata.video_codec === 'hevc') {
                    videoCodec = 'hvc1.1.6.L93.B0';
                }

                // Setup Audio Tracks UI (Only once effectively, but re-population is safe)
                const audioTracks = metadata.audio_tracks || [];
                if (audioTracks.length > 1) {
                    audioSelect.style.display = 'block';
                    audioSelect.innerHTML = audioTracks.map(track => {
                        const label = track.label || track.language || `Track ${track.index + 1}`;
                        const codec = track.codec === 'aac' ? '' : ` (${track.codec})`;
                        const selected = track.index === currentAudioTrackIndex ? 'selected' : '';
                        return `<option value="${track.index}" ${selected}>${label}${codec}</option>`;
                    }).join('');

                    // Remove old listener to avoid duplicates if any (though we usually don't need to if element persists)
                    // Better: use 'onchange' property or ensure single add.
                    audioSelect.onchange = (e) => {
                        const newIndex = parseInt(e.target.value);
                        if (newIndex !== currentAudioTrackIndex) {
                            console.log(`Switching audio track to ${newIndex}`);
                            currentAudioTrackIndex = newIndex;
                            startStream(videoElement.currentTime);
                        }
                    };
                }

                // Setup Subtitle Tracks UI
                const subtitleTracks = metadata.subtitle_tracks || [];
                if (subtitleTracks.length > 0) {
                    subtitleSelect.style.display = 'block';
                    const options = subtitleTracks.map(track => {
                        const label = track.label || track.language || `Track ${track.index + 1}`;
                        // const selected = track.index === currentSubtitleIndex ? 'selected' : ''; // Default off
                        return `<option value="${track.index}">${label}</option>`;
                    }).join('');

                    // Prepend "Off" option (already in HTML, but if we overwrite innerHTML we need to keep it)
                    subtitleSelect.innerHTML = `<option value="-1" selected>Subtitles: Off</option>` + options;

                    subtitleSelect.onchange = (e) => {
                        const trackIndex = parseInt(e.target.value);
                        console.log(`Switching subtitle track to ${trackIndex}`);

                        // Remove existing tracks
                        const existingTracks = videoElement.querySelectorAll('track');
                        existingTracks.forEach(t => t.remove());

                        if (trackIndex !== -1) {
                            const trackData = subtitleTracks.find(t => t.index === trackIndex);
                            if (trackData) {
                                const track = document.createElement('track');
                                track.kind = 'subtitles';
                                track.label = trackData.label || trackData.language || `Track ${trackIndex + 1}`;
                                track.srclang = trackData.language || 'en';
                                track.src = `/api/subtitles?path=${encodeURIComponent(moviePath)}&index=${trackIndex}`;
                                track.default = true;
                                videoElement.appendChild(track);

                                // Ensure it shows
                                // Accessing track.track might require waiting for append? Usually unexpected but let's see.
                                // track.track.mode = 'showing';
                            }
                        }
                    };
                }

                // Construct MIME
                const hasAudio = audioTracks.length > 0;
                let outputMime = `video/mp4; codecs="${videoCodec}`;
                if (hasAudio) {
                    outputMime += ',mp4a.40.2';
                }
                outputMime += '"';

                if (!MediaSource.isTypeSupported(outputMime)) {
                    alert(`Browser does not support codec: ${outputMime}`);
                    return;
                }

                const sourceBuffer = mediaSource.addSourceBuffer(outputMime);
                sourceBuffer.mode = 'segments';

                // --- Streaming Logic ---
                let abortController = null;
                const queue = [];

                const cleanupBuffer = () => {
                    if (mediaSource.readyState !== 'open' || sourceBuffer.updating) return;
                    const removeEnd = videoElement.currentTime - 30;
                    if (removeEnd > 0) {
                        try {
                            sourceBuffer.remove(0, removeEnd);
                        } catch (e) {
                            console.error('Remove error:', e);
                        }
                    }
                };

                const appendNext = () => {
                    if (mediaSource.readyState !== 'open') return;

                    // Error Check Phase
                    if (videoElement.error) {
                        console.error('Playback Error detected:', videoElement.error);

                        // Recovery Logic
                        if (videoElement.error.code === 3) { // MEDIA_ERR_DECODE
                            const now = Date.now();
                            if (now - lastDecodeErrorTime > 5000) {
                                console.warn("Attempting to recover from decode error by reloading player skipping 2s...");
                                lastDecodeErrorTime = now;
                                const targetTime = videoElement.currentTime + 2.0;

                                // FULL RELOAD
                                loadVideo(targetTime);
                                return;
                            } else {
                                console.error("Too many decode errors. Giving up.");
                                return;
                            }
                        } else {
                            console.error("Fatal playback error.");
                            return;
                        }
                    }

                    if (queue.length > 0 && !sourceBuffer.updating) {
                        try {
                            sourceBuffer.appendBuffer(queue[0]);
                            queue.shift();
                        } catch (e) {
                            if (e.name === 'QuotaExceededError') {
                                cleanupBuffer();
                            } else {
                                console.error('Append error:', e);
                                queue.shift();
                            }
                        }
                    }
                };

                sourceBuffer.addEventListener('updateend', appendNext);
                sourceBuffer.addEventListener('error', (e) => console.error('SourceBuffer error:', e));

                // Start Stream Inner Function
                const startStream = async (timeToStart) => {
                    // Retry / Busy check
                    let retryCount = 0;
                    const maxRetries = 20;

                    const activeStart = async () => {
                        try {
                            if (abortController) abortController.abort();
                            abortController = new AbortController();
                            currentAbortController = abortController; // Track globally for cleanup
                            const signal = abortController.signal;

                            queue.length = 0;

                            // Abort any current sourceBuffer op
                            if (mediaSource.readyState === 'open') {
                                try { sourceBuffer.abort(); } catch (e) { }
                            }

                            // Wait for not updating
                            let safeties = 0;
                            while (sourceBuffer.updating && safeties < 20) {
                                await new Promise(r => setTimeout(r, 20));
                                safeties++;
                            }

                            // Flush for seek/restart
                            if (mediaSource.readyState === 'open' && !sourceBuffer.updating) {
                                try {
                                    sourceBuffer.remove(0, Infinity);
                                    let s2 = 0;
                                    while (sourceBuffer.updating && s2 < 50) {
                                        await new Promise(r => setTimeout(r, 20));
                                        s2++;
                                    }
                                } catch (e) { console.warn("Flush failed", e); }
                            }

                            if (sourceBuffer.updating) {
                                if (retryCount < maxRetries) {
                                    retryCount++;
                                    setTimeout(activeStart, 100);
                                    return;
                                }
                                return;
                            }

                            // Re-open if ended
                            if (mediaSource.readyState === 'ended') {
                                try {
                                    // abort() transitions 'ended' -> 'open' per spec
                                    sourceBuffer.abort();
                                } catch (e) {
                                    console.warn("Failed to re-open via abort:", e);
                                }
                            }

                            if (mediaSource.readyState === 'open') {
                                sourceBuffer.timestampOffset = timeToStart;
                            } else {
                                console.error("MediaSource not open during startStream, attempting full reload.");
                                loadVideo(timeToStart);
                                return;
                            }

                            console.log(`Fetching stream: ${timeToStart}s`);
                            const response = await fetch(`/api/stream?path=${encodeURIComponent(moviePath)}&start=${timeToStart}&audio_track=${currentAudioTrackIndex}`, { signal });
                            if (!response.ok) throw new Error(`Stream fetch failed: ${response.status}`);

                            const reader = response.body.getReader();
                            let totalBytes = 0;

                            while (true) {
                                if (signal.aborted) break;
                                if (mediaSource.readyState !== 'open') break;

                                if (sourceBuffer.buffered.length > 0) {
                                    const end = sourceBuffer.buffered.end(sourceBuffer.buffered.length - 1);
                                    if (end - videoElement.currentTime > 30) {
                                        await new Promise(r => setTimeout(r, 1000));
                                        if (!queue.length && !sourceBuffer.updating) appendNext();
                                        continue;
                                    }
                                }

                                const { done, value } = await reader.read();
                                if (done) {
                                    if (mediaSource.readyState === 'open' && !signal.aborted) {
                                        // Wait for queue to drain and final update to complete
                                        let eosSafeties = 0;
                                        while ((sourceBuffer.updating || queue.length > 0) && eosSafeties < 100) {
                                            await new Promise(r => setTimeout(r, 50));
                                            eosSafeties++;
                                        }
                                        if (!sourceBuffer.updating && queue.length === 0) {
                                            console.log("Stream complete, calling endOfStream.");
                                            mediaSource.endOfStream();
                                        } else {
                                            console.warn("Timed out waiting for buffer update/queue drain before cleanup.");
                                        }
                                    }
                                }

                                if (value && value.byteLength > 0) {
                                    totalBytes += value.byteLength;
                                    queue.push(value);

                                    // Immediate error check
                                    if (videoElement.error) {
                                        // This will be caught by appendNext or next loop
                                        console.error("Stream loop detected error");
                                        break;
                                    }
                                    if (!sourceBuffer.updating) appendNext();
                                }
                            }

                        } catch (e) {
                            if (e.name !== 'AbortError') console.error("Stream Loop Error:", e);
                        }
                    };
                    activeStart();
                };

                // Define Seeking Handler (capturing current scope's startStream)
                videoElement.onseeking = () => {
                    console.log(`Seek detected: ${videoElement.currentTime}`);
                    startStream(videoElement.currentTime);
                };

                // Initial start logic
                if (startPosition > 0) {
                    console.log(`Restoring position to ${startPosition}s`);
                    videoElement.currentTime = startPosition;
                }

                // Explicitly start stream to guarantee loading
                startStream(startPosition);

                // Safely attempt play when ready
                const tryPlay = () => {
                    videoElement.play().catch(e => {
                        if (e.name !== 'AbortError') console.log("Autoplay blocked or waiting", e);
                    });
                };

                videoElement.addEventListener('canplay', tryPlay, { once: true });
                videoElement.addEventListener('canplaythrough', tryPlay, { once: true });

            } catch (e) {
                console.error("Setup error in sourceopen:", e);
            }
        });
    };

    // Kickoff
    loadVideo(0);
});
