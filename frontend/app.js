const moviesGrid = document.getElementById('moviesGrid');
const breadcrumbs = document.getElementById('breadcrumbs');

let movieTree = []; // Current view nodes
let navigationStack = []; // Stack of { name, path, children }
let folderCache = new Map(); // path -> nodes[]
let currentLibraryId = null;
let libraries = [];

// Fetch configured libraries
async function fetchLibraries() {
    try {
        const res = await fetch('/api/libraries');
        if (res.status === 401) {
            window.location.href = '/login.html';
            return [];
        }
        if (res.ok) {
            libraries = await res.json();
            return libraries;
        }
    } catch (e) {
        console.error("Failed to fetch libraries", e);
    }
    return [];
}

// Fetch movies for a specific path
async function fetchMovies(path = '') {
    if (!currentLibraryId) return null;

    // Cache key needs to include libraryId
    const cacheKey = `${currentLibraryId}:${path}`;

    if (folderCache.has(cacheKey)) {
        return folderCache.get(cacheKey);
    }
    try {
        const url = `/api/movies?path=${encodeURIComponent(path)}&library_id=${currentLibraryId}`;
        const response = await fetch(url);
        if (response.status === 401) {
            window.location.href = '/login.html';
            return null;
        }
        if (!response.ok) throw new Error('Fetch failed');
        const nodes = await response.json();
        folderCache.set(cacheKey, nodes);
        return nodes;
    } catch (error) {
        console.error('Error fetching movies:', error);
        moviesGrid.innerHTML = '<p class="error">Failed to load movies.</p>';
        return null;
    }
}

async function initLibrary() {
    await fetchLibraries();

    // Check navigation state to see if we were inside a library
    const savedLibId = sessionStorage.getItem('currentLibraryId');
    const savedStack = sessionStorage.getItem('navigationStack');

    if (savedLibId && libraries.some(l => l.id === savedLibId)) {
        currentLibraryId = savedLibId;
        // Try to restore stack
        if (savedStack) {
            try {
                const stackData = JSON.parse(savedStack);
                // Reconstruct stack logic... similarly to before but with library context
                // For simplicity, let's start at library root if simple restore fails or just load root.
                // Or implement full restore:

                const rootNodes = await fetchMovies('');
                navigationStack = [{ name: getLibraryName(savedLibId), path: '', children: rootNodes }];

                // Rebuild levels
                for (let i = 1; i < stackData.length; i++) {
                    const { name, path } = stackData[i];
                    const nodes = await fetchMovies(path);
                    if (nodes) {
                        navigationStack.push({ name, path, children: nodes });
                    } else {
                        break;
                    }
                }
                renderUI();
                return;
            } catch (e) {
                console.error("Restore failed", e);
            }
        }
        // Fallback to library root
        await enterLibrary(libraries.find(l => l.id === savedLibId), false);
    } else {
        renderLibraries();
    }
}

function getLibraryName(id) {
    const lib = libraries.find(l => l.id === id);
    return lib ? lib.name : 'Library';
}

function renderLibraries() {
    currentLibraryId = null;
    sessionStorage.removeItem('currentLibraryId');
    sessionStorage.removeItem('navigationStack');

    moviesGrid.innerHTML = '';
    breadcrumbs.innerHTML = '<span class="breadcrumb-item active">Home</span>';

    libraries.forEach(lib => {
        const card = document.createElement('div');
        card.className = 'movie-card folder';

        // Menu handling
        const menuContainer = document.createElement('div');
        menuContainer.className = 'card-menu';
        menuContainer.innerHTML = `
            <button class="card-menu-btn">⋮</button>
            <div class="card-menu-dropdown">
                <div class="card-menu-item edit">
                    <span>✏️</span> Edit
                </div>
                <div class="card-menu-item delete">
                    <span>🗑️</span> Delete
                </div>
            </div>
        `;

        const btn = menuContainer.querySelector('.card-menu-btn');
        const dropdown = menuContainer.querySelector('.card-menu-dropdown');
        const editBtn = menuContainer.querySelector('.card-menu-item.edit');
        const deleteBtn = menuContainer.querySelector('.card-menu-item.delete');

        btn.onclick = (e) => {
            e.stopPropagation();
            // Close other dropdowns
            document.querySelectorAll('.card-menu-dropdown.show').forEach(d => {
                if (d !== dropdown) d.classList.remove('show');
            });
            dropdown.classList.toggle('show');
        };

        editBtn.onclick = (e) => {
            e.stopPropagation();
            window.location.href = `/add-library.html?id=${lib.id}`;
        };

        deleteBtn.onclick = async (e) => {
            e.stopPropagation();
            if (confirm(`Are you sure you want to delete library "${lib.name}"?`)) {
                try {
                    const res = await fetch(`/api/libraries/${lib.id}`, { method: 'DELETE' });
                    if (res.ok) {
                        await initLibrary(); // Reload
                    } else {
                        alert('Failed to delete library');
                    }
                } catch (err) {
                    console.error(err);
                    alert('Error deleting library');
                }
            }
        };

        // Close dropdown when clicking elsewhere (handled globally ideally, but we can do per-setup or simple)
        // Ideally global listener. Let's add one global listener in init?
        // For now, let's rely on global listener we will add or simple card click closes others?
        // Better: simple global listener logic that we'll add separately.

        // Determine image based on type
        let bgImage = 'library_other.png';
        if (lib.kind === 'Movies') bgImage = 'library_movies.png';
        if (lib.kind === 'TVShows') bgImage = 'library_tv.png';

        card.style.backgroundImage = `linear-gradient(to bottom, rgba(0,0,0,0) 0%, rgba(0,0,0,0.8) 100%), url('${bgImage}')`;
        card.style.backgroundSize = 'cover';
        card.style.backgroundPosition = 'center';

        card.innerHTML = `
            <div class="movie-icon" style="opacity:0">📚</div>
            <div class="movie-title">${lib.name}</div>
        `;
        card.appendChild(menuContainer);

        card.onclick = () => enterLibrary(lib);
        moviesGrid.appendChild(card);
    });

    // Add Library Card
    const addCard = document.createElement('div');
    addCard.className = 'movie-card';
    addCard.innerHTML = `
        <div class="movie-icon">➕</div>
        <div class="movie-title">Add Library</div>
    `;
    addCard.onclick = () => window.location.href = '/add-library.html';
    moviesGrid.appendChild(addCard);
}

async function enterLibrary(lib, render = true) {
    currentLibraryId = lib.id;
    sessionStorage.setItem('currentLibraryId', lib.id);

    const rootNodes = await fetchMovies('');
    if (rootNodes) {
        navigationStack = [{ name: lib.name, path: '', children: rootNodes }];
        if (render) renderUI();
    }
}

function renderUI() {
    renderBreadcrumbs();
    const currentFolder = navigationStack[navigationStack.length - 1];
    movieTree = currentFolder.children;
    renderGrid(movieTree);
}

function renderBreadcrumbs() {
    breadcrumbs.innerHTML = '';

    // Home link
    const home = document.createElement('span');
    home.className = 'breadcrumb-item';
    home.textContent = 'Home';
    home.onclick = () => renderLibraries();
    breadcrumbs.appendChild(home);

    navigationStack.forEach((node, index) => {
        const item = document.createElement('span');
        item.className = 'breadcrumb-item';
        if (index === navigationStack.length - 1) {
            item.classList.add('active');
        }
        item.textContent = node.name;
        item.onclick = async () => {
            navigationStack = navigationStack.slice(0, index + 1);
            renderUI();
            saveNavigationState();
        };
        breadcrumbs.appendChild(item);
    });
}

function renderGrid(nodes) {
    moviesGrid.innerHTML = '';

    // "Back" logic handled by Breadcrumbs primarily, or we can add back button to go up/home
    if (navigationStack.length > 1) {
        // Back to parent folder
        const backCard = document.createElement('div');
        backCard.className = 'movie-card folder back';
        backCard.onclick = () => {
            navigationStack.pop();
            renderUI();
            saveNavigationState();
        };
        backCard.innerHTML = `<div class="movie-icon">⬅️</div><div class="movie-title">Back</div>`;
        moviesGrid.appendChild(backCard);
    } else {
        // Back to Libraries
        const backCard = document.createElement('div');
        backCard.className = 'movie-card folder back';
        backCard.onclick = () => renderLibraries();
        backCard.innerHTML = `<div class="movie-icon">🏠</div><div class="movie-title">Libraries</div>`;
        moviesGrid.appendChild(backCard);
    }

    if (nodes.length === 0) {
        moviesGrid.innerHTML = '<p style="grid-column: 1/-1; text-align: center; color: var(--text-muted);">This folder is empty.</p>';
        return;
    }

    nodes.forEach(node => {
        const card = document.createElement('div');
        card.className = 'movie-card';

        // Poster Logic
        if (node.poster) {
            // New logic: Use serve_content route
            // node.path is relative to library root. 
            // node.poster is relative name from handler (usually "Movie.jpg")
            // BUT implementation in list_files:
            // poster = Some("Movie.jpg")
            // We need full path relative to library root.
            // list_files returns 'path': "Action/Movie.mkv".
            // Poster lives at "Action/Movie.jpg".
            // So we take parent of node.path + node.poster.

            const lastSlash = node.path.lastIndexOf('/');
            const parentPath = lastSlash !== -1 ? node.path.substring(0, lastSlash + 1) : '';
            // Construct path valid for serve_content
            const contentPath = `${parentPath}${node.poster}`;

            const posterUrl = `/api/libraries/${currentLibraryId}/content/${contentPath}`;
            const escapedUrl = encodeURI(posterUrl).replace(/'/g, "%27");

            card.style.backgroundImage = `linear-gradient(to bottom, rgba(0,0,0,0) 0%, rgba(0,0,0,0.8) 100%), url('${escapedUrl}')`;
            card.style.backgroundSize = 'cover';
            card.style.backgroundPosition = 'center';
        }

        if (node.type === 'folder') {
            card.classList.add('folder');
            card.onclick = async () => {
                const children = await fetchMovies(node.path);
                if (children) {
                    navigationStack.push({ name: node.name, path: node.path, children });
                    renderUI();
                    saveNavigationState();
                }
            };

            const displayTitle = node.title || node.name;
            card.innerHTML = `
                <div class="movie-icon" ${node.poster ? 'style="opacity:0"' : ''}>📁</div>
                <div class="movie-title">${displayTitle}</div>
            `;
            // Lookup button...
            appendLookupBtn(node, card);

            // Auto lookup season logic
            const isSeason = node.path.includes('Shows/') && (node.name.toLowerCase().includes('season') || /^s\d+/i.test(node.name));
            if (!node.poster && isSeason) {
                setTimeout(() => lookupMovie(node, card, true), 100);
            }

        } else {
            card.onclick = () => playMovie(node);
            const displayTitle = node.title || node.name;
            card.innerHTML = `
                <div class="movie-icon" ${node.poster ? 'style="opacity:0"' : ''}>🎬</div>
                <div class="movie-title">${displayTitle}</div>
            `;
            appendLookupBtn(node, card);
        }
        moviesGrid.appendChild(card);
    });
}

function appendLookupBtn(node, card) {
    const lookupBtn = document.createElement('div');
    lookupBtn.className = 'lookup-btn';
    lookupBtn.innerHTML = '🔍';
    lookupBtn.title = 'Lookup Metadata';
    lookupBtn.onclick = (e) => {
        e.stopPropagation();
        lookupMovie(node, card);
    };
    card.appendChild(lookupBtn);
}

function playMovie(movie) {
    saveNavigationState();
    sessionStorage.setItem('currentMoviePath', movie.path);
    sessionStorage.setItem('currentMovieName', movie.name);
    // Pass library ID to player?
    // Player needs to know how to stream.
    // We should update player.html logic too, or pass query params.
    window.location.href = `player.html?library_id=${currentLibraryId}`;
}

function saveNavigationState() {
    const stackData = navigationStack.map(n => ({ name: n.name, path: n.path }));
    sessionStorage.setItem('navigationStack', JSON.stringify(stackData));
}

async function lookupMovie(node, cardElement, silent = false) {
    const btn = cardElement.querySelector('.lookup-btn');
    const originalIcon = btn ? btn.innerHTML : '🔍';
    if (btn) btn.innerHTML = '⏳';

    try {
        const response = await fetch(`/api/lookup?path=${encodeURIComponent(node.path)}&library_id=${currentLibraryId}`);
        if (response.status === 401) {
            window.location.href = '/login.html';
            return;
        }
        if (!response.ok) throw new Error('Lookup failed');
        const data = await response.json();

        if (data) {
            if (data.title) node.title = data.title;
            if (data.poster_path) node.poster = `${node.name}.jpg`;
            renderUI();
        } else {
            if (!silent) alert('No metadata found for this item.');
            if (btn) btn.innerHTML = originalIcon;
        }
    } catch (e) {
        console.error("Lookup error:", e);
        if (!silent) alert('Lookup failed.');
        if (btn) btn.innerHTML = originalIcon;
    }
}

async function checkUser() {
    try {
        const res = await fetch('/api/me');
        if (res.ok) {
            const user = await res.json();
            const profile = document.getElementById('userProfile');
            if (profile) {
                profile.innerHTML = `
                    <span style="margin-right: 1rem; color: #fff; font-weight: bold;">User: ${user.username}</span>
                    <button id="profileBtn" class="logout-btn" style="margin-right: 0.5rem; background-color: #444;">Profile</button>
                    <button id="logoutBtn" class="logout-btn">Logout</button>
                `;
                document.getElementById('profileBtn').addEventListener('click', () => {
                    window.location.href = '/profile.html';
                });
                document.getElementById('logoutBtn').addEventListener('click', async () => {
                    await fetch('/api/logout', { method: 'POST' });
                    // Clear session storage
                    sessionStorage.clear();
                    window.location.reload();
                });
            }
        }
    } catch (e) {
        console.error("Failed to fetch user", e);
    }
}

checkUser();
initLibrary();

// Global click listener to close dropdowns
document.addEventListener('click', (e) => {
    if (!e.target.closest('.card-menu')) {
        document.querySelectorAll('.card-menu-dropdown.show').forEach(d => {
            d.classList.remove('show');
        });
    }
});
