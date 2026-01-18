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

    mediaSource.addEventListener('sourceopen', async () => {
        try {
            console.log(`Probing stream for: ${moviePath}`);
            const probeController = new AbortController();
            const probeResponse = await fetch(`/api/stream?path=${encodeURIComponent(moviePath)}`, {
                signal: probeController.signal
            });

            if (!probeResponse.ok) throw new Error(`Probe fetch failed: ${probeResponse.status}`);

            // Dynamic Codec Detection from Header
            const serverCodec = probeResponse.headers.get('X-Video-Codec');
            const hasAudio = probeResponse.headers.get('X-Has-Audio') !== 'false';
            const serverDuration = parseFloat(probeResponse.headers.get('X-Video-Duration'));

            console.log(`Server signals: Codec=${serverCodec}, Audio=${hasAudio}, Duration=${serverDuration}`);

            // Cancel the probe request immediately as we only needed headers
            // We use the controller abort to sever connection immediately
            probeController.abort();

            // Set duration if valid
            if (!isNaN(serverDuration) && serverDuration > 0) {
                mediaSource.duration = serverDuration;
            }

            // Base video codecs
            let videoCodec = 'avc1.4d4028'; // Default H.264
            if (serverCodec === 'hevc') {
                videoCodec = 'hvc1.1.6.L93.B0'; // HEVC
            }

            // Construct full MIME
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

            const appendNext = () => {
                if (mediaSource.readyState !== 'open') return;

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
                try {
                    if (mediaSource.readyState === 'open') {
                        sourceBuffer.abort();
                    }
                } catch (e) {
                    console.warn('Abort error:', e);
                }

                // Wait for updating to clear
                let safeties = 0;
                while (sourceBuffer.updating && safeties < 20) {
                    await new Promise(r => setTimeout(r, 20));
                    safeties++;
                }

                // FLUSH BUFFER: Remove all existing data to prevent timeline conflicts (backwards seek issue)
                try {
                    if (mediaSource.readyState === 'open' && !sourceBuffer.updating) {
                        console.log("Flushing buffer...");
                        sourceBuffer.remove(0, Infinity);

                        // Wait for remove() to finish
                        let removeSafeties = 0;
                        while (sourceBuffer.updating && removeSafeties < 50) { // Give it up to 1s
                            await new Promise(r => setTimeout(r, 20));
                            removeSafeties++;
                        }
                        console.log("Buffer flushed.");
                    }
                } catch (e) {
                    console.warn("Buffer flush failed:", e);
                }

                if (sourceBuffer.updating) {
                    console.warn(`SourceBuffer busy after flush, retrying stream start (${retryCount + 1})...`);
                    setTimeout(() => startStream(startTime, retryCount + 1), 100);
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

                try {
                    if (mediaSource.readyState === 'open') {
                        sourceBuffer.timestampOffset = startTime;
                        console.log(`TimestampOffset set to ${startTime}`);
                    } else {
                        console.error(`MediaSource state is ${mediaSource.readyState}. Cannot set timestampOffset or seek.`);
                        return;
                    }
                } catch (e) {
                    console.error("Failed to set timestampOffset:", e);
                    return; // Stop here
                }

                try {
                    console.log(`Fetching stream for: ${moviePath} at ${startTime}s`);
                    const response = await fetch(`/api/stream?path=${encodeURIComponent(moviePath)}&start=${startTime}`, { signal });
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
                            if (!sourceBuffer.updating) appendNext();
                        }
                    }
                } catch (e) {
                    if (e.name === 'AbortError' || e.message.includes('Aborted') || e.message.includes('aborted')) {
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
