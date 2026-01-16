const moviesGrid = document.getElementById('moviesGrid');
const breadcrumbs = document.getElementById('breadcrumbs');

let movieTree = []; // Current view nodes
let navigationStack = []; // Stack of { name, path, children }
let folderCache = new Map(); // path -> nodes[]

// Fetch movies for a specific path
async function fetchMovies(path = '') {
    if (folderCache.has(path)) {
        return folderCache.get(path);
    }
    try {
        const response = await fetch(`/api/movies?path=${encodeURIComponent(path)}`);
        if (!response.ok) throw new Error('Fetch failed');
        const nodes = await response.json();
        folderCache.set(path, nodes);
        return nodes;
    } catch (error) {
        console.error('Error fetching movies:', error);
        moviesGrid.innerHTML = '<p class="error">Failed to load movies.</p>';
        return null;
    }
}

async function initLibrary() {
    const rootNodes = await fetchMovies('');
    if (!rootNodes) return;

    // Try to restore navigation state
    const savedStack = sessionStorage.getItem('navigationStack');
    if (savedStack) {
        try {
            const stackData = JSON.parse(savedStack); // Array of {name, path}
            navigationStack = [{ name: 'Home', path: '', children: rootNodes }];

            // Rebuild stack by fetching each level
            for (let i = 1; i < stackData.length; i++) {
                const { name, path } = stackData[i];
                const nodes = await fetchMovies(path);
                if (nodes) {
                    navigationStack.push({ name, path, children: nodes });
                } else {
                    break;
                }
            }
        } catch (e) {
            console.error("Failed to restore navigation state:", e);
            navigationStack = [{ name: 'Home', path: '', children: rootNodes }];
        }
    } else {
        navigationStack = [{ name: 'Home', path: '', children: rootNodes }];
    }

    renderUI();
}

function renderUI() {
    renderBreadcrumbs();
    const currentFolder = navigationStack[navigationStack.length - 1];
    movieTree = currentFolder.children;
    renderGrid(movieTree);
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

    // Add Back button if not at home
    if (navigationStack.length > 1) {
        const backCard = document.createElement('div');
        backCard.className = 'movie-card folder back';
        backCard.onclick = () => {
            navigationStack.pop();
            renderUI();
            saveNavigationState();
        };
        backCard.innerHTML = `
            <div class="movie-icon">⬅️</div>
            <div class="movie-title">Back</div>
        `;
        moviesGrid.appendChild(backCard);
    }

    if (nodes.length === 0) {
        moviesGrid.innerHTML = '<p style="grid-column: 1/-1; text-align: center; color: var(--text-muted);">This folder is empty.</p>';
        return;
    }

    nodes.forEach(node => {
        const card = document.createElement('div');
        card.className = 'movie-card';

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

function playMovie(movie) {
    saveNavigationState();
    sessionStorage.setItem('currentMoviePath', movie.path);
    sessionStorage.setItem('currentMovieName', movie.name);
    window.location.href = 'player.html';
}

function saveNavigationState() {
    const stackData = navigationStack.map(n => ({ name: n.name, path: n.path }));
    sessionStorage.setItem('navigationStack', JSON.stringify(stackData));
}



initLibrary();
