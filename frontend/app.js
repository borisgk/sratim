const moviesGrid = document.getElementById('moviesGrid');
const searchInput = document.getElementById('searchInput');
const breadcrumbs = document.getElementById('breadcrumbs');

let movieTree = [];
let navigationStack = []; // Stack of folder nodes

// Fetch movies on load
async function fetchMovies() {
    try {
        const response = await fetch('/api/movies');
        movieTree = await response.json();

        // Try to restore navigation state
        const savedStack = sessionStorage.getItem('navigationStack');
        if (savedStack) {
            try {
                const names = JSON.parse(savedStack);
                navigationStack = [{ name: 'Home', children: movieTree }];

                // Rebuild stack by finding nodes in the tree
                let currentLevel = movieTree;
                for (let i = 1; i < names.length; i++) {
                    const found = currentLevel.find(n => n.name === names[i] && n.type === 'folder');
                    if (found) {
                        navigationStack.push(found);
                        currentLevel = found.children;
                    } else {
                        break; // Stop if folder not found
                    }
                }
            } catch (e) {
                console.error("Failed to restore navigation state:", e);
                navigationStack = [{ name: 'Home', children: movieTree }];
            }
        } else {
            navigationStack = [{ name: 'Home', children: movieTree }];
        }

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

function playMovie(movie) {
    // Save navigation state (just the folder names to reconstruct the stack)
    const stackNames = navigationStack.map(node => node.name);
    sessionStorage.setItem('navigationStack', JSON.stringify(stackNames));

    // Pass movie data via sessionStorage to keep the URL clean
    sessionStorage.setItem('currentMoviePath', movie.path);
    sessionStorage.setItem('currentMovieName', movie.name);

    // Navigate to player page without query parameters
    window.location.href = 'player.html';
}

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

fetchMovies();
