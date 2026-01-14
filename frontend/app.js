const moviesGrid = document.getElementById('moviesGrid');
const searchInput = document.getElementById('searchInput');
const playerContainer = document.getElementById('playerContainer');
const mainVideo = document.getElementById('mainVideo');
const nowPlayingTitle = document.getElementById('nowPlayingTitle');
const customControls = document.getElementById('customControls');
const seekBar = document.getElementById('seekBar');
const timeDisplay = document.getElementById('timeDisplay');
const durationDisplay = document.getElementById('durationDisplay');
const closePlayerBtn = document.getElementById('closePlayer');
const playPauseBtn = document.getElementById('playPauseBtn');
const fullscreenBtn = document.getElementById('fullscreenBtn');
const breadcrumbs = document.getElementById('breadcrumbs');
// Video wrapper for fullscreen
const videoWrapper = document.querySelector('.video-wrapper');

let currentTranscodeOffset = 0;
let totalDuration = 0;
let isTranscoding = false;

let movieTree = [];
let navigationStack = []; // Stack of folder nodes

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

// Fetch movies on load
async function fetchMovies() {
    try {
        const response = await fetch('/api/movies');
        movieTree = await response.json();

        // Initial state: Root
        navigationStack = [{ name: 'Home', children: movieTree }];
        renderUI();
    } catch (error) {
        console.error('Error fetching movies:', error);
        moviesGrid.innerHTML = '<p class="error">Failed to load movies.</p>';
    }
}

function renderUI() {
    renderBreadcrumbs();
    const currentFolder = navigationStack[navigationStack.length - 1];
    renderGrid(currentFolder.children);
}

function renderBreadcrumbs() {
    breadcrumbs.innerHTML = '';
    navigationStack.forEach((node, index) => {
        const item = document.createElement('span');
        item.className = 'breadcrumb-item';
        if (index === navigationStack.length - 1) {
            item.classList.add('active');
        }
        item.textContent = node.name;
        item.onclick = () => {
            navigationStack = navigationStack.slice(0, index + 1);
            renderUI();
        };
        breadcrumbs.appendChild(item);
    });
}

function renderGrid(nodes) {
    moviesGrid.innerHTML = '';

    // Add Back button if not at home
    if (navigationStack.length > 1) {
        const backCard = document.createElement('div');
        backCard.className = 'movie-card folder back';
        backCard.onclick = () => {
            navigationStack.pop();
            renderUI();
        };
        backCard.innerHTML = `
            <div class="movie-icon">⬅️</div>
            <div class="movie-title">Back</div>
        `;
        moviesGrid.appendChild(backCard);
    }

    if (nodes.length === 0 && navigationStack.length === 1) {
        moviesGrid.innerHTML = '<p style="grid-column: 1/-1; text-align: center; color: var(--text-muted);">No movies found.</p>';
        return;
    }

    nodes.forEach(node => {
        const card = document.createElement('div');
        card.className = 'movie-card';

        if (node.type === 'folder') {
            card.classList.add('folder');
            card.onclick = () => {
                navigationStack.push(node);
                renderUI();
            };
            card.innerHTML = `
                <div class="movie-icon">📁</div>
                <div class="movie-title">${node.name}</div>
            `;
        } else {
            card.onclick = () => playMovie(node);
            card.innerHTML = `
                <div class="movie-icon">🎬</div>
                <div class="movie-title">${node.name}</div>
            `;
        }

        moviesGrid.appendChild(card);
    });
}

async function playMovie(movie) {
    nowPlayingTitle.textContent = `Loading: ${movie.name}...`;
    playerContainer.classList.remove('hidden');
    customControls.classList.add('hidden'); // hidden by default
    mainVideo.controls = true; // Default to native

    // Check metadata first
    try {
        const metaRes = await fetch(`/api/metadata?path=${encodeURIComponent(movie.path)}`);
        if (metaRes.ok) {
            const meta = await metaRes.json();
            console.log("Media Metadata:", meta);

            // Store duration if available
            if (meta.duration) {
                totalDuration = meta.duration;
            } else {
                totalDuration = 0;
            }

            const badAudio = ['ac3', 'dts', 'eac3', 'truehd'];
            const badVideo = ['vp9']; // Browsers generally support HEVC/H265 now if hardware is present

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
                startTranscode(movie, reason);
                return;
            }
        }
    } catch (e) {
        console.error("Failed to check metadata, falling back to try-play", e);
    }

    // Try Native Playback
    startNative(movie);
}

function startNative(movie) {
    isTranscoding = false;
    currentTranscodeOffset = 0;
    const originalUrl = `/content/${encodeURI(movie.path)}`;
    mainVideo.onerror = null;
    mainVideo.src = originalUrl;
    nowPlayingTitle.textContent = `Now Playing: ${movie.name}`;

    mainVideo.onerror = (e) => {
        console.log("Native playback failed, switching to transcode...", e);
        startTranscode(movie, "Playback Error");
    };

    mainVideo.play().catch(e => console.log("Autoplay prevented:", e));
}

function startTranscode(movie, reason, startTime = 0) {
    isTranscoding = true;
    currentTranscodeOffset = startTime;

    // Switch to custom controls
    mainVideo.controls = false;
    customControls.classList.remove('hidden');

    const transcodeUrl = `/api/transcode?path=${encodeURIComponent(movie.path)}&start=${startTime}`;
    nowPlayingTitle.textContent = `Transcoding (${reason}): ${movie.name}`;

    // Reset error handler to prevent loops
    mainVideo.onerror = null;
    mainVideo.src = transcodeUrl;

    // Setup Seek Bar
    if (totalDuration > 0) {
        seekBar.max = totalDuration;
        durationDisplay.textContent = formatTime(totalDuration);
    } else {
        seekBar.max = 100; // Unknown duration
        durationDisplay.textContent = "??:??";
    }

    mainVideo.play().catch(e => console.log("Autoplay prevented:", e));

    // Seeking Handler
    seekBar.onchange = (e) => {
        const seekTime = parseFloat(e.target.value);
        console.log("Seeking to:", seekTime);
        startTranscode(movie, "Seek", seekTime);
    };
}

// Update loop
mainVideo.ontimeupdate = () => {
    if (isTranscoding) {
        // In transcoding, video.currentTime is relative to the segment start
        // Current 'Real' Time = offset + video.currentTime
        const realTime = currentTranscodeOffset + mainVideo.currentTime;
        seekBar.value = realTime;
        timeDisplay.textContent = formatTime(realTime);
    } else {
        // Native playback
    }
};

closePlayerBtn.onclick = () => {
    mainVideo.pause();
    mainVideo.src = '';
    playerContainer.classList.add('hidden');
    customControls.classList.add('hidden');
    nowPlayingTitle.textContent = 'Select a movie';
    isTranscoding = false;
};

// Search filter
searchInput.addEventListener('input', (e) => {
    const term = e.target.value.toLowerCase();

    if (term === '') {
        renderUI();
        return;
    }

    // Search flattens the result
    const results = [];
    function searchRecursive(nodes) {
        nodes.forEach(node => {
            if (node.type === 'file' && node.name.toLowerCase().includes(term)) {
                results.push(node);
            } else if (node.type === 'folder') {
                searchRecursive(node.children);
            }
        });
    }
    searchRecursive(movieTree);

    // Clear breadcrumbs during search
    breadcrumbs.innerHTML = '<span class="breadcrumb-item active">Search Results</span>';
    renderGrid(results);
});

// Play/Pause Logic
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

// Fullscreen Logic
fullscreenBtn.onclick = () => {
    if (!document.fullscreenElement) {
        videoWrapper.requestFullscreen().catch(err => {
            console.error(`Error attempting to enable fullscreen: ${err.message}`);
        });
    } else {
        document.exitFullscreen();
    }
};

fetchMovies();
