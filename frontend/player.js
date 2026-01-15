const mainVideo = document.getElementById('mainVideo');
const nowPlayingTitle = document.getElementById('nowPlayingTitle');
const customControls = document.getElementById('customControls');
const seekBar = document.getElementById('seekBar');
const timeDisplay = document.getElementById('timeDisplay');
const durationDisplay = document.getElementById('durationDisplay');
const playPauseBtn = document.getElementById('playPauseBtn');
const fullscreenBtn = document.getElementById('fullscreenBtn');
const videoWrapper = document.querySelector('.video-wrapper');
const subtitleSelect = document.getElementById('subtitleSelect');

let currentTranscodeOffset = 0;
let totalDuration = 0;
let isTranscoding = false;
let currentMoviePath = '';
let currentMovieName = '';
let lastSeekTime = null;
let userSeeking = false; // Flag to prevent seekBar updates during user interaction

// Debug overlay elements (will be initialized in initPlayer)
let debugOverlay, debugMode, debugVideoTime, debugOffset, debugRealTime, debugCodec, debugLastSeek;

// Helper
function formatTime(seconds) {
    const h = Math.floor(seconds / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    const s = Math.floor(seconds % 60);

    if (h > 0) {
        return `${h}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
    }
    return `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
}

async function initPlayer() {
    // Initialize debug overlay elements
    debugOverlay = document.getElementById('debugOverlay');
    debugMode = document.getElementById('debugMode');
    debugVideoTime = document.getElementById('debugVideoTime');
    debugOffset = document.getElementById('debugOffset');
    debugRealTime = document.getElementById('debugRealTime');
    debugCodec = document.getElementById('debugCodec');
    debugLastSeek = document.getElementById('debugLastSeek');

    // Keep debug overlay hidden by default (toggle with 'D')
    debugOverlay.style.display = 'none';

    // Keyboard shortcut to toggle debug overlay (D key)
    window.addEventListener('keydown', (e) => {
        if (e.key === 'd' || e.key === 'D') {
            debugOverlay.style.display = debugOverlay.style.display === 'none' ? 'block' : 'none';
        }
    });

    // Initialize UI controls once
    mainVideo.controls = false;
    customControls.classList.remove('hidden');

    // Track when user starts interacting with seek bar
    seekBar.onmousedown = () => {
        userSeeking = true;
    };

    // Instant seek when user releases
    seekBar.onmouseup = (e) => {
        userSeeking = false;
        const seekTime = parseFloat(e.target.value);
        performSeek(seekTime);
    };

    // Also handle direct clicks (without drag)
    seekBar.onclick = (e) => {
        const seekTime = parseFloat(e.target.value);
        performSeek(seekTime);
    };

    // Retrieve movie data from sessionStorage
    currentMoviePath = sessionStorage.getItem('currentMoviePath');
    currentMovieName = sessionStorage.getItem('currentMovieName');

    if (!currentMoviePath || !currentMovieName) {
        nowPlayingTitle.textContent = "Error: Movie data missing. Returning to library...";
        setTimeout(() => {
            window.location.href = 'index.html';
        }, 2000);
        return;
    }

    nowPlayingTitle.textContent = `Loading: ${currentMovieName}...`;

    try {
        const metaRes = await fetch(`/api/metadata?path=${encodeURIComponent(currentMoviePath)}`);
        if (metaRes.ok) {
            const meta = await metaRes.json();
            console.log("Media Metadata:", meta);

            if (meta.duration) {
                totalDuration = meta.duration;
            } else {
                totalDuration = 0;
            }

            const badAudio = ['ac3', 'dts', 'eac3', 'truehd'];
            const badVideo = ['vp9'];

            const audioCodec = (meta.audio_codec || "").toLowerCase();
            const videoCodec = (meta.video_codec || "").toLowerCase();
            const container = (meta.container || "").toLowerCase();

            // Update debug overlay codec info
            debugCodec.textContent = `V:${videoCodec} A:${audioCodec} C:${container}`;

            let shouldTranscode = false;
            let reason = "";

            if (badAudio.some(c => audioCodec.includes(c))) {
                shouldTranscode = true;
                reason = `Unsupported Audio (${audioCodec})`;
            } else if (badVideo.some(c => videoCodec.includes(c))) {
                shouldTranscode = true;
                reason = `Unsupported Video (${videoCodec})`;
            } else if (container === 'mkv') {
                shouldTranscode = true;
                reason = `MKV Container`;
            }

            if (shouldTranscode) {
                console.log(`Force transcoding due to: ${reason}`);
                startTranscode(reason);
                // We return here to prevent startNative from being called
                // Subtitles will be loaded below
            }

            // Load Subtitles
            if (meta.subtitles && meta.subtitles.length > 0) {
                console.log("Loading subtitles:", meta.subtitles);
                meta.subtitles.forEach((sub, idx) => {
                    const track = document.createElement('track');
                    track.kind = 'subtitles';
                    track.label = sub.title || sub.language || `Subtitle ${sub.index}`;
                    track.srclang = sub.language || 'und';
                    track.src = `/api/subtitles?path=${encodeURIComponent(currentMoviePath)}&index=${sub.index}`;

                    // Enable first track by default
                    if (idx === 0) {
                        track.default = true;
                    }

                    mainVideo.appendChild(track);

                    // Add to dropdown
                    const option = document.createElement('option');
                    option.value = sub.index;
                    option.textContent = track.label;
                    subtitleSelect.appendChild(option);
                });

                // Link dropdown to track switching
                subtitleSelect.onchange = (e) => {
                    const val = e.target.value;
                    const tracks = mainVideo.textTracks;
                    for (let i = 0; i < tracks.length; i++) {
                        if (val === 'off') {
                            tracks[i].mode = 'disabled';
                        } else {
                            // Match by label or index if needed, but here simple index suffices
                            // as we added them in order
                            tracks[i].mode = (i === subtitleSelect.selectedIndex - 1) ? 'showing' : 'disabled';
                        }
                    }
                };

                // Set default in dropdown
                if (meta.subtitles.length > 0) {
                    subtitleSelect.selectedIndex = 1; // First sub after "Off"
                }
            }

            if (shouldTranscode) return; // Exit after setting up subs and starting transcode
        }
    } catch (e) {
        console.error("Failed to check metadata, falling back to try-play", e);
    }

    startNative();
}

function startNative() {
    isTranscoding = false;
    currentTranscodeOffset = 0;
    const originalUrl = `/content/${encodeURI(currentMoviePath)}?t=${Date.now()}`;
    mainVideo.onerror = null;
    mainVideo.controls = false;
    mainVideo.src = originalUrl;
    nowPlayingTitle.textContent = `Now Playing: ${currentMovieName}`;

    if (totalDuration > 0) {
        seekBar.max = totalDuration;
        durationDisplay.textContent = formatTime(totalDuration);
    } else {
        seekBar.max = 100;
        durationDisplay.textContent = "??:??";
    }

    mainVideo.onerror = (e) => {
        console.log("Native playback failed, switching to transcode...", e);
        startTranscode("Playback Error");
    };

    mainVideo.play().catch(e => console.log("Autoplay prevented:", e));
}

function performSeek(seekTime) {
    // Validate: don't seek beyond duration
    if (totalDuration > 0 && seekTime > totalDuration - 1) {
        seekTime = totalDuration - 1;
        seekBar.value = seekTime;
        console.log(`Clamped seek to ${seekTime.toFixed(2)}s`);
    }

    console.log(`Seeking to: ${seekTime.toFixed(2)}s`);
    debugLastSeek.textContent = `${seekTime.toFixed(2)}s`;

    if (isTranscoding) {
        // For transcoding, we need to restart the FFmpeg process with a new -ss
        startTranscode("Seek", seekTime);
    } else {
        // For native playback, standard HTML5 seeking
        mainVideo.currentTime = seekTime;
    }
}

function startTranscode(reason, startTime = 0) {
    isTranscoding = true;
    currentTranscodeOffset = startTime;
    lastSeekTime = startTime;

    const transcodeUrl = `/api/transcode?path=${encodeURIComponent(currentMoviePath)}&start=${startTime}&t=${Date.now()}`;
    nowPlayingTitle.textContent = `Transcoding (${reason}): ${currentMovieName}`;

    mainVideo.onerror = null;
    mainVideo.controls = false;
    mainVideo.src = transcodeUrl;

    if (totalDuration > 0) {
        seekBar.max = totalDuration;
        durationDisplay.textContent = formatTime(totalDuration);
    } else {
        seekBar.max = 100;
        durationDisplay.textContent = "??:??";
    }

    mainVideo.play().catch(e => console.log("Autoplay prevented:", e));
}

mainVideo.ontimeupdate = () => {
    let realTime = 0;
    if (isTranscoding) {
        realTime = currentTranscodeOffset + mainVideo.currentTime;
    } else {
        realTime = mainVideo.currentTime;
    }

    // Only update seek bar if user isn't currently interacting with it
    if (!userSeeking) {
        seekBar.value = realTime;
    }

    timeDisplay.textContent = formatTime(realTime);

    // Update debug overlay
    debugVideoTime.textContent = mainVideo.currentTime.toFixed(2);
    debugOffset.textContent = currentTranscodeOffset.toFixed(2);
    debugRealTime.textContent = realTime.toFixed(2);
    debugMode.textContent = isTranscoding ? 'Transcoding' : 'Native';
};

playPauseBtn.onclick = () => {
    if (mainVideo.paused) {
        mainVideo.play();
    } else {
        mainVideo.pause();
    }
};

mainVideo.onplay = () => {
    playPauseBtn.textContent = '⏸️';
};

mainVideo.onpause = () => {
    playPauseBtn.textContent = '▶️';
};

fullscreenBtn.onclick = () => {
    if (!document.fullscreenElement) {
        videoWrapper.requestFullscreen().catch(err => {
            console.error(`Error attempting to enable fullscreen: ${err.message}`);
        });
    } else {
        document.exitFullscreen();
    }
};

window.onload = initPlayer;
