/**
 * Spatial Navigation Manager for Sratim TV
 */

document.addEventListener('DOMContentLoaded', () => {
    // 1. Find all focusable elements
    const focusables = Array.from(document.querySelectorAll('[data-focusable="true"]'));
    
    if (focusables.length === 0) return;

    // 2. Set initial focus
    let currentFocusIndex = 0;
    // Prefer to focus the first actual content card in the grid, rather than the header buttons
    let focusedElement = document.querySelector('.tv-grid [data-focusable="true"]') || focusables[0];
    
    // Check if we came back from a player and need to restore focus state
    const savedPath = sessionStorage.getItem('tv_last_focused_path');
    if (savedPath) {
        const matchingEl = focusables.find(f => f.dataset.path === savedPath || f.dataset.url === savedPath);
        if (matchingEl) {
            focusedElement = matchingEl;
        }
    }

    setFocus(focusedElement);

    // 3. Handle Keydown Engine
    document.addEventListener('keydown', (e) => {
        if (!['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Enter', 'Escape', 'Backspace'].includes(e.key)) {
            return;
        }

        // Allow typing in text inputs
        if (document.activeElement && (document.activeElement.tagName === 'INPUT' || document.activeElement.tagName === 'TEXTAREA')) {
            if (['ArrowLeft', 'ArrowRight', 'Backspace'].includes(e.key)) {
                return; // Let the user type/move cursor inside the input
            }
        }

        e.preventDefault();

        if (e.key === 'Enter') {
            handleAction(focusedElement);
            return;
        }

        if (e.key === 'Escape' || e.key === 'Backspace') {
            // Attempt to find a 'Back' button and click it
            const backBtn = document.querySelector('.tv-breadcrumb-back');
            if (backBtn) {
                handleAction(backBtn);
            }
            return;
        }

        // Calculate spatial navigation
        const nextElement = getNextFocusElement(focusedElement, e.key, focusables);
        if (nextElement) {
            setFocus(nextElement);
        }
    });

    function setFocus(el) {
        if (focusedElement) {
            focusedElement.classList.remove('active-focus');
        }
        focusedElement = el;
        focusedElement.classList.add('active-focus');
        
        // Native focus for inputs
        if (el.tagName === 'INPUT' || el.tagName === 'BUTTON') {
            el.focus();
        } else if (document.activeElement && document.activeElement !== document.body) {
            document.activeElement.blur();
        }
        
        // Ensure into view (scroll the grid container if needed)
        // Since we disabled overflow scrolling globally, we adjust translated Y coordinates of the grid
        scrollIntoViewTV(focusedElement);
    }

    function scrollIntoViewTV(el) {
        // A simple scrolling mechanism
        const grid = document.querySelector('.tv-grid');
        if (!grid) return;
        
        const elRect = el.getBoundingClientRect();
        
        // If element is off the bottom screen
        if (elRect.bottom > window.innerHeight - 50) {
            const currentTransform = getTransformY(grid);
            const neededScroll = elRect.bottom - (window.innerHeight - 100);
            grid.style.transform = `translateY(${currentTransform - neededScroll}px)`;
        } 
        // If element is off the top screen
        else if (elRect.top < 200) { // 200 is header height approx
            const currentTransform = getTransformY(grid);
            const neededScroll = 200 - elRect.top;
            const newTransform = currentTransform + neededScroll;
            // don't scroll past 0
            grid.style.transform = `translateY(${Math.min(0, newTransform)}px)`;
        }
        grid.style.transition = "transform 0.3s ease-out";
    }

    function getTransformY(el) {
        const style = window.getComputedStyle(el);
        const matrix = new DOMMatrixReadOnly(style.transform);
        return matrix.m42; 
    }

    // Distance-based closest neighbor algorithm
    function getNextFocusElement(current, direction, items) {
        const cRect = current.getBoundingClientRect();
        let closest = null;
        let minDistance = Infinity;

        items.forEach(target => {
            if (target === current) return;
            const tRect = target.getBoundingClientRect();
            
            let isCandidate = false;

            // Determine if target is in the correct direction
            switch (direction) {
                case 'ArrowUp':
                    isCandidate = tRect.bottom <= cRect.top + 20; // 20px tolerance for uneven grids
                    break;
                case 'ArrowDown':
                    isCandidate = tRect.top >= cRect.bottom - 20;
                    break;
                case 'ArrowLeft':
                    isCandidate = tRect.right <= cRect.left + 20;
                    break;
                case 'ArrowRight':
                    isCandidate = tRect.left >= cRect.right - 20;
                    break;
            }

            if (isCandidate) {
                // Calculate distance between center points
                const cCenterX = cRect.left + cRect.width / 2;
                const cCenterY = cRect.top + cRect.height / 2;
                
                const tCenterX = tRect.left + tRect.width / 2;
                const tCenterY = tRect.top + tRect.height / 2;

                const distance = Math.sqrt(Math.pow(cCenterX - tCenterX, 2) + Math.pow(cCenterY - tCenterY, 2));

                if (distance < minDistance) {
                    minDistance = distance;
                    closest = target;
                }
            }
        });

        // Special fallback: If going right and no candidate is found because it's a new row, wrap around might be desired.
        // For standard TV grids, basic proximity is usually enough.

        return closest;
    }

    function handleAction(el) {
        const action = el.dataset.action;
        
        // Save current selection to restore when navigating back
        if (el.dataset.path) sessionStorage.setItem('tv_last_focused_path', el.dataset.path);
        else if (el.dataset.url) sessionStorage.setItem('tv_last_focused_path', el.dataset.url);

        if (action === 'link') {
            window.location.href = el.dataset.url;
        } else if (action === 'submit') {
            el.click(); // Trigger native click for submit buttons
        } else if (action === 'logout') {
            fetch('/api/logout', { method: 'POST' }).then(() => {
                sessionStorage.clear();
                window.location.href = '/tv_login.html';
            });
        } else if (action === 'play') {
            const path = el.dataset.path;
            const lib = el.dataset.lib;
            
            const form = document.getElementById('watch-form');
            document.getElementById('watch-path').value = decodeURIComponent(path);
            document.getElementById('watch-lib').value = lib;
            form.submit();
        }
    }
});
