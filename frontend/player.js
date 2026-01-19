document.addEventListener('DOMContentLoaded', async () => {
    const videoElement = document.getElementById('mainVideo');
    const moviePath = sessionStorage.getItem('currentMoviePath');

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

    const mediaSource = new MediaSource();
    videoElement.src = URL.createObjectURL(mediaSource);

    let currentAudioTrackIndex = 0;
    const audioSelect = document.getElementById('audioTrackSelect');

    mediaSource.addEventListener('sourceopen', async () => {
        try {
            console.log(`Fetching metadata for: ${moviePath}`);
            const metaResponse = await fetch(`/api/metadata?path=${encodeURIComponent(moviePath)}`);
            if (!metaResponse.ok) throw new Error(`Metadata fetch failed: ${metaResponse.status}`);
            const metadata = await metaResponse.json();

            console.log('Metadata:', metadata);

            // Setup Duration
            if (metadata.duration && metadata.duration > 0) {
                mediaSource.duration = metadata.duration;
            }

            // Setup Video Codec
            let videoCodec = 'avc1.4d4028';
            if (metadata.video_codec === 'hevc') {
                videoCodec = 'hvc1.1.6.L93.B0';
            }

            // Setup Audio Tracks API
            const audioTracks = metadata.audio_tracks || [];
            if (audioTracks.length > 1) {
                audioSelect.style.display = 'block';
                audioSelect.innerHTML = audioTracks.map(track => {
                    const label = track.label || track.language || `Track ${track.index + 1}`;
                    const codec = track.codec === 'aac' ? '' : ` (${track.codec})`;
                    return `<option value="${track.index}">${label}${codec}</option>`;
                }).join('');

                audioSelect.addEventListener('change', (e) => {
                    const newIndex = parseInt(e.target.value);
                    if (newIndex !== currentAudioTrackIndex) {
                        console.log(`Switching audio track to ${newIndex}`);
                        currentAudioTrackIndex = newIndex;

                        const wasPlaying = !videoElement.paused;

                        // Restart stream immediately at current time
                        startStream(videoElement.currentTime);

                        // Signal intent to play immediately (browser will buffer)
                        if (wasPlaying) {
                            console.log("Resuming playback after track switch...");
                            videoElement.play().catch(e => console.warn("Resume failed:", e));
                        }
                    }
                });
            }

            // Construct MIME
            // We assume audio is present if tracks > 0
            const hasAudio = audioTracks.length > 0;
            let outputMime = `video/mp4; codecs="${videoCodec}`;
            if (hasAudio) {
                outputMime += ',mp4a.40.2';
            }
            outputMime += '"';

            console.log(`Initializing SourceBuffer with: ${outputMime}`);

            if (!MediaSource.isTypeSupported(outputMime)) {
                alert(`Browser does not support the required codec: ${outputMime}`);
                return;
            }

            const sourceBuffer = mediaSource.addSourceBuffer(outputMime);
            sourceBuffer.mode = 'segments';

            // Stream Management
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

            let lastDecodeErrorTime = 0;

            const appendNext = () => {
                if (mediaSource.readyState !== 'open') return;

                if (videoElement.error) {
                    console.error('Playback Error detected:', videoElement.error);

                    if (videoElement.error.code === 3) { // MEDIA_ERR_DECODE
                        const now = Date.now();
                        if (now - lastDecodeErrorTime > 5000) {
                            console.warn("Attempting to recover from decode error by skipping 2s...");
                            lastDecodeErrorTime = now;
                            const targetTime = videoElement.currentTime + 2.0;
                            // Forced restart at new time
                            startStream(targetTime);
                            return;
                        } else {
                            console.error("Too many decode errors in rapid succession. Stopping.");
                            return;
                        }
                    } else {
                        // Not a decode error, just stop
                        console.error('Non-recoverable error, stopping append.');
                        return;
                    }
                }

                if (queue.length > 0 && !sourceBuffer.updating) {
                    try {
                        sourceBuffer.appendBuffer(queue[0]);
                        queue.shift();
                    } catch (e) {
                        if (e.name === 'QuotaExceededError') {
                            console.warn('Buffer quota exceeded. Attempting cleanup.');
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

            // Start Stream Function
            const startStream = async (startTime = 0, retryCount = 0) => {
                try {
                    if (retryCount > 20) {
                        console.error("Failed to start stream after multiple retries (buffer busy).");
                        return;
                    }

                    if (abortController) {
                        abortController.abort();
                    }
                    abortController = new AbortController();
                    const signal = abortController.signal;

                    // Clear queue
                    queue.length = 0;

                    // Reset parser state via abort()
                    if (mediaSource.readyState === 'open') {
                        try {
                            sourceBuffer.abort();
                        } catch (e) {
                            console.warn('Abort error:', e);
                        }
                    }

                    // Wait for updating to clear
                    let safeties = 0;
                    while (sourceBuffer.updating && safeties < 20) {
                        await new Promise(r => setTimeout(r, 20));
                        safeties++;
                    }

                    // FLUSH BUFFER: Remove all existing data to prevent timeline conflicts (backwards seek issue)
                    if (mediaSource.readyState === 'open' && !sourceBuffer.updating) {
                        try {
                            console.log("Flushing buffer...");
                            sourceBuffer.remove(0, Infinity);

                            // Wait for remove() to finish
                            let removeSafeties = 0;
                            while (sourceBuffer.updating && removeSafeties < 50) { // Give it up to 1s
                                await new Promise(r => setTimeout(r, 20));
                                removeSafeties++;
                            }
                            console.log("Buffer flushed.");
                        } catch (e) {
                            console.warn("Buffer flush failed:", e);
                        }
                    }

                    if (sourceBuffer.updating) {
                        console.warn(`SourceBuffer busy after flush, retrying stream start (${retryCount + 1})...`);
                        setTimeout(() => startStream(startTime, retryCount + 1).catch(e => console.warn("Retry failed:", e)), 100);
                        return;
                    }

                    // Ensure MediaSource is open before setting timestampOffset
                    if (mediaSource.readyState === 'ended') {
                        try {
                            console.log("MediaSource ended, re-opening via abort()...");
                            sourceBuffer.abort();
                        } catch (e) {
                            console.warn("Failed to re-open MediaSource:", e);
                        }
                    }

                    if (mediaSource.readyState === 'open') {
                        sourceBuffer.timestampOffset = startTime;
                        console.log(`TimestampOffset set to ${startTime}`);
                    } else {
                        console.error(`MediaSource state is ${mediaSource.readyState}. Cannot set timestampOffset or seek.`);
                        return;
                    }

                    console.log(`Fetching stream for: ${moviePath} at ${startTime}s (AudioTrack: ${currentAudioTrackIndex})`);
                    const response = await fetch(`/api/stream?path=${encodeURIComponent(moviePath)}&start=${startTime}&audio_track=${currentAudioTrackIndex}`, { signal });
                    if (!response.ok) throw new Error(`Fetch failed: ${response.status}`);

                    console.log("Stream connected, reading...");
                    const reader = response.body.getReader();

                    let totalBytes = 0;
                    while (true) {
                        if (signal.aborted) {
                            console.debug("Previous stream fetch stopped (cleanup).");
                            break;
                        }

                        // Debug buffered ranges occasionally
                        if (totalBytes % (1024 * 1024) === 0) { // Every 1MB approx
                            let ranges = [];
                            for (let i = 0; i < sourceBuffer.buffered.length; i++) {
                                ranges.push(`${sourceBuffer.buffered.start(i).toFixed(2)}-${sourceBuffer.buffered.end(i).toFixed(2)}`);
                            }
                            console.log(`Buffered ranges: [${ranges.join(', ')}], Current: ${videoElement.currentTime}`);
                        }

                        // Flow control
                        if (sourceBuffer.buffered.length > 0) {
                            const bufferedEnd = sourceBuffer.buffered.end(sourceBuffer.buffered.length - 1);
                            if (bufferedEnd - videoElement.currentTime > 30) {
                                await new Promise(r => setTimeout(r, 1000));
                                if (!queue.length && !sourceBuffer.updating) appendNext();
                                continue;
                            }
                        }

                        const { done, value } = await reader.read();
                        if (done) {
                            console.log("Stream finished");
                            if (mediaSource.readyState === 'open' && !signal.aborted) {
                                mediaSource.endOfStream();
                            }
                            break;
                        }

                        if (value && value.byteLength > 0) {
                            totalBytes += value.byteLength;
                            queue.push(value);
                            if (videoElement.error) {
                                console.error('Video element error detected in stream loop:', videoElement.error);
                                break;
                            }
                            if (!sourceBuffer.updating) appendNext();
                        }
                    }
                } catch (e) {
                    if (e.name === 'AbortError' || e.message.includes('Aborted') || e.message.includes('aborted') || e.message.includes('BodyStreamBuffer')) {
                        console.debug('Fetch request cancelled (cleanup).');
                    } else {
                        console.error("Stream error loop:", e);
                    }
                }
            };

            // Handle Seek
            videoElement.addEventListener('seeking', () => {
                console.log(`User seeking to: ${videoElement.currentTime}`);

                // User requested to always restart stream to ensure stability, 
                // ignoring any potentially existing buffer.
                console.log('Seek detected. Restarting stream (forced).');
                const time = videoElement.currentTime;
                startStream(time).catch(e => console.error("StartStream failed on seek:", e));
            });

            // Initial start
            startStream(0);
        } catch (e) {
            console.error("Setup error:", e);
        }
    });
});
