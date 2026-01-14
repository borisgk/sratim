const mainVideo = document.getElementById('mainVideo');
const nowPlayingTitle = document.getElementById('nowPlayingTitle');
const customControls = document.getElementById('customControls');
const seekBar = document.getElementById('seekBar');
const timeDisplay = document.getElementById('timeDisplay');
const durationDisplay = document.getElementById('durationDisplay');
const playPauseBtn = document.getElementById('playPauseBtn');
const fullscreenBtn = document.getElementById('fullscreenBtn');
const videoWrapper = document.querySelector('.video-wrapper');

let currentTranscodeOffset = 0;
let totalDuration = 0;
let isTranscoding = false;
let currentMoviePath = '';
let currentMovieName = '';

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
    customControls.classList.add('hidden');
    mainVideo.controls = true;

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
                return;
            }
        }
    } catch (e) {
        console.error("Failed to check metadata, falling back to try-play", e);
    }

    startNative();
}

function startNative() {
    isTranscoding = false;
    currentTranscodeOffset = 0;
    const originalUrl = `/content/${encodeURI(currentMoviePath)}`;
    mainVideo.onerror = null;
    mainVideo.src = originalUrl;
    nowPlayingTitle.textContent = `Now Playing: ${currentMovieName}`;

    mainVideo.onerror = (e) => {
        console.log("Native playback failed, switching to transcode...", e);
        startTranscode("Playback Error");
    };

    mainVideo.play().catch(e => console.log("Autoplay prevented:", e));
}

function startTranscode(reason, startTime = 0) {
    isTranscoding = true;
    currentTranscodeOffset = startTime;

    mainVideo.controls = false;
    customControls.classList.remove('hidden');

    const transcodeUrl = `/api/transcode?path=${encodeURIComponent(currentMoviePath)}&start=${startTime}`;
    nowPlayingTitle.textContent = `Transcoding (${reason}): ${currentMovieName}`;

    mainVideo.onerror = null;
    mainVideo.src = transcodeUrl;

    if (totalDuration > 0) {
        seekBar.max = totalDuration;
        durationDisplay.textContent = formatTime(totalDuration);
    } else {
        seekBar.max = 100;
        durationDisplay.textContent = "??:??";
    }

    mainVideo.play().catch(e => console.log("Autoplay prevented:", e));

    seekBar.onchange = (e) => {
        const seekTime = parseFloat(e.target.value);
        console.log("Seeking to:", seekTime);
        startTranscode("Seek", seekTime);
    };
}

mainVideo.ontimeupdate = () => {
    if (isTranscoding) {
        const realTime = currentTranscodeOffset + mainVideo.currentTime;
        seekBar.value = realTime;
        timeDisplay.textContent = formatTime(realTime);
    }
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
