        (function() {
            let currentData = window.INITIAL_ANALYTICS;
            let currentRange = currentData.range || '30d';
            let currentContentType = 'movies';
            let currentSort = 'time';

            function escapeHtml(str) {
                if (!str) return '';
                return String(str)
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;')
                    .replace(/'/g, '&#39;');
            }

            function formatDuration(seconds) {
                if (seconds >= 3600) {
                    const h = Math.floor(seconds / 3600);
                    const m = Math.floor((seconds % 3600) / 60);
                    return `${h}h ${m < 10 ? '0' : ''}${m}m`;
                } else if (seconds >= 60) {
                    const m = Math.floor(seconds / 60);
                    const s = Math.floor(seconds % 60);
                    return `${m}m ${s < 10 ? '0' : ''}${s}s`;
                }
                return `${seconds}s`;
            }

            function formatRelativeDate(epochSeconds) {
                if (!epochSeconds) return 'Never';
                const now = Math.floor(Date.now() / 1000);
                const diff = Math.max(0, now - epochSeconds);
                if (diff < 60) return 'Just now';
                if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
                if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
                return `${Math.floor(diff / 86400)}d ago`;
            }

            function updateKpis(overview) {
                document.getElementById('kpi-watch-time').innerText = formatDuration(overview.total_watch_seconds || 0);
                document.getElementById('kpi-total-plays').innerText = (overview.total_plays || 0).toLocaleString();
                document.getElementById('kpi-active-viewers').innerText = (overview.active_viewers || 0).toLocaleString();
                const h = overview.peak_hour || 0;
                const nextH = (h + 1) % 24;
                document.getElementById('kpi-peak-hour').innerText = `${String(h).padStart(2, '0')}:00 - ${String(nextH).padStart(2, '0')}:00`;
            }

            function renderTrendChart(trendPoints) {
                const svg = document.getElementById('trend-svg');
                const tooltip = document.getElementById('trend-tooltip');
                const container = document.getElementById('trend-container');

                if (!trendPoints || trendPoints.length === 0) {
                    svg.innerHTML = `<text x="300" y="120" fill="#6b7280" font-size="14" text-anchor="middle">No playback events recorded in this time period.</text>`;
                    return;
                }

                const width = 600;
                const height = 240;
                const padLeft = 45;
                const padRight = 20;
                const padTop = 20;
                const padBottom = 35;
                const plotW = width - padLeft - padRight;
                const plotH = height - padTop - padBottom;

                let maxSec = 0;
                for (const p of trendPoints) {
                    if (p.seconds > maxSec) maxSec = p.seconds;
                }
                if (maxSec === 0) maxSec = 3600; // default 1 hr ceiling

                const n = trendPoints.length;
                const coords = [];
                for (let i = 0; i < n; i++) {
                    const x = padLeft + (n > 1 ? (i / (n - 1)) * plotW : plotW / 2);
                    const y = padTop + plotH - (trendPoints[i].seconds / maxSec) * plotH;
                    coords.push({ x, y, data: trendPoints[i] });
                }

                // Smooth path generator
                let linePath = `M ${coords[0].x} ${coords[0].y}`;
                for (let i = 1; i < coords.length; i++) {
                    const prev = coords[i - 1];
                    const curr = coords[i];
                    const cpx = (prev.x + curr.x) / 2;
                    linePath += ` C ${cpx} ${prev.y}, ${cpx} ${curr.y}, ${curr.x} ${curr.y}`;
                }
                const areaPath = `${linePath} L ${coords[coords.length - 1].x} ${padTop + plotH} L ${coords[0].x} ${padTop + plotH} Z`;

                // SVG Grid lines
                let gridHtml = '';
                for (let g = 0; g <= 4; g++) {
                    const gy = padTop + (plotH / 4) * g;
                    const val = Math.round(((4 - g) / 4) * (maxSec / 3600) * 10) / 10;
                    gridHtml += `
                        <line x1="${padLeft}" y1="${gy}" x2="${width - padRight}" y2="${gy}" stroke="rgba(255, 255, 255, 0.06)" stroke-dasharray="3,3" />
                        <text x="${padLeft - 8}" y="${gy + 4}" fill="#6b7280" font-size="10" text-anchor="end">${val}h</text>
                    `;
                }

                // X-axis date labels (show up to 6 labels)
                const step = Math.max(1, Math.floor(n / 6));
                for (let i = 0; i < n; i += step) {
                    const c = coords[i];
                    const datePart = c.data.date ? c.data.date.substring(5) : '';
                    gridHtml += `<text x="${c.x}" y="${height - 10}" fill="#6b7280" font-size="10" text-anchor="middle">${datePart}</text>`;
                }

                svg.innerHTML = `
                    <defs>
                        <linearGradient id="trendGrad" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%" stop-color="#38bdf8" stop-opacity="0.45" />
                            <stop offset="100%" stop-color="#6366f1" stop-opacity="0.0" />
                        </linearGradient>
                    </defs>
                    ${gridHtml}
                    <path d="${areaPath}" fill="url(#trendGrad)" />
                    <path d="${linePath}" fill="none" stroke="#38bdf8" stroke-width="2.5" stroke-linecap="round" />
                `;

                // Add interactive hover points
                coords.forEach(pt => {
                    const circle = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
                    circle.setAttribute('cx', pt.x);
                    circle.setAttribute('cy', pt.y);
                    circle.setAttribute('r', '4');
                    circle.setAttribute('fill', '#0284c7');
                    circle.setAttribute('stroke', '#ffffff');
                    circle.setAttribute('stroke-width', '2');
                    circle.style.cursor = 'pointer';
                    circle.style.transition = 'r 0.15s ease';

                    circle.addEventListener('mouseenter', () => {
                        circle.setAttribute('r', '7');
                        tooltip.innerHTML = `<strong>${pt.data.date}</strong><br/>Watch Time: ${formatDuration(pt.data.seconds)}<br/>Plays: ${pt.data.plays}`;
                        tooltip.style.opacity = '1';
                        const rect = container.getBoundingClientRect();
                        const clientX = (pt.x / width) * rect.width;
                        const clientY = (pt.y / height) * rect.height;
                        tooltip.style.left = `${clientX}px`;
                        tooltip.style.top = `${clientY}px`;
                    });

                    circle.addEventListener('mouseleave', () => {
                        circle.setAttribute('r', '4');
                        tooltip.style.opacity = '0';
                    });

                    svg.appendChild(circle);
                });
            }

            function renderHourlyChart(hourlyData, peakHour) {
                const svg = document.getElementById('hourly-svg');
                const tooltip = document.getElementById('hourly-tooltip');
                const container = document.getElementById('hourly-container');

                const width = 600;
                const height = 240;
                const padLeft = 45;
                const padRight = 15;
                const padTop = 20;
                const padBottom = 35;
                const plotW = width - padLeft - padRight;
                const plotH = height - padTop - padBottom;

                let maxVal = 0;
                for (const v of hourlyData) {
                    if (v > maxVal) maxVal = v;
                }
                if (maxVal === 0) maxVal = 3600;

                const barSlot = plotW / 24;
                const barWidth = Math.max(4, barSlot * 0.65);

                let gridHtml = '';
                for (let g = 0; g <= 4; g++) {
                    const gy = padTop + (plotH / 4) * g;
                    const val = Math.round(((4 - g) / 4) * (maxVal / 3600) * 10) / 10;
                    gridHtml += `
                        <line x1="${padLeft}" y1="${gy}" x2="${width - padRight}" y2="${gy}" stroke="rgba(255, 255, 255, 0.06)" stroke-dasharray="3,3" />
                        <text x="${padLeft - 8}" y="${gy + 4}" fill="#6b7280" font-size="10" text-anchor="end">${val}h</text>
                    `;
                }

                // X labels for hours (every 4 hours)
                for (let h = 0; h < 24; h += 4) {
                    const bx = padLeft + h * barSlot + barSlot / 2;
                    gridHtml += `<text x="${bx}" y="${height - 10}" fill="#6b7280" font-size="10" text-anchor="middle">${String(h).padStart(2, '0')}:00</text>`;
                }

                svg.innerHTML = `
                    <defs>
                        <linearGradient id="normalBar" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%" stop-color="#6366f1" />
                            <stop offset="100%" stop-color="#4338ca" />
                        </linearGradient>
                        <linearGradient id="peakBar" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="0%" stop-color="#38bdf8" />
                            <stop offset="100%" stop-color="#0284c7" />
                        </linearGradient>
                    </defs>
                    ${gridHtml}
                `;

                hourlyData.forEach((val, h) => {
                    const bh = (val / maxVal) * plotH;
                    const bx = padLeft + h * barSlot + (barSlot - barWidth) / 2;
                    const by = padTop + plotH - bh;
                    const isPeak = (h === peakHour && val > 0);

                    const rect = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
                    rect.setAttribute('x', bx);
                    rect.setAttribute('y', by);
                    rect.setAttribute('width', barWidth);
                    rect.setAttribute('height', Math.max(2, bh));
                    rect.setAttribute('rx', '3');
                    rect.setAttribute('fill', isPeak ? 'url(#peakBar)' : 'url(#normalBar)');
                    rect.style.cursor = 'pointer';
                    rect.style.transition = 'opacity 0.2s ease';

                    rect.addEventListener('mouseenter', () => {
                        rect.style.opacity = '0.75';
                        const nextH = (h + 1) % 24;
                        tooltip.innerHTML = `<strong>${String(h).padStart(2, '0')}:00 - ${String(nextH).padStart(2, '0')}:00</strong><br/>Watch Time: ${formatDuration(val)}${isPeak ? '<br/><span style="color:#38bdf8;font-weight:700;">★ Peak Hour</span>' : ''}`;
                        tooltip.style.opacity = '1';
                        const cRect = container.getBoundingClientRect();
                        const clientX = ((bx + barWidth / 2) / width) * cRect.width;
                        const clientY = (by / height) * cRect.height;
                        tooltip.style.left = `${clientX}px`;
                        tooltip.style.top = `${clientY}px`;
                    });

                    rect.addEventListener('mouseleave', () => {
                        rect.style.opacity = '1';
                        tooltip.style.opacity = '0';
                    });

                    svg.appendChild(rect);
                });
            }

            function getPosterUrl(path) {
                if (!path || typeof path !== 'string') return null;
                const clean = path.trim();
                if (clean === '') return null;
                if (clean.startsWith('http://') || clean.startsWith('https://')) return clean;
                if (clean.startsWith('/images/')) return clean;
                if (clean.startsWith('/')) return `/images/posters/w185${clean}`;
                return `/images/posters/w185/${clean}`;
            }

            function renderLeaderboard(items, isShows) {
                const grid = document.getElementById('leaderboard-grid');
                grid.innerHTML = '';

                if (!items || items.length === 0) {
                    grid.innerHTML = `<div style="grid-column: 1 / -1; padding: 40px; text-align: center; color: #9ca3af;">No viewing activity recorded for this content type in the selected window.</div>`;
                    return;
                }

                items.forEach((item, idx) => {
                    const rank = idx + 1;
                    let rankClass = '';
                    if (rank === 1) rankClass = 'gold';
                    else if (rank === 2) rankClass = 'silver';
                    else if (rank === 3) rankClass = 'bronze';

                    const card = document.createElement('div');
                    card.className = 'media-rank-card';
                    card.style.cursor = 'pointer';

                    const detailHref = isShows 
                        ? (item.show_id ? `/show?id=${item.show_id}` : null) 
                        : (item.movie_id ? `/details?id=${item.movie_id}` : null);
                    if (detailHref) {
                        card.addEventListener('click', () => { window.location.href = detailHref; });
                    }

                    const posterUrl = getPosterUrl(item.poster_path);
                    const defaultIcon = isShows
                        ? `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="22" height="22"><rect x="2" y="7" width="20" height="15" rx="2" ry="2"></rect><polyline points="17 2 12 7 7 2"></polyline></svg>`
                        : `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="22" height="22"><rect x="2" y="2" width="20" height="20" rx="2.18"></rect><line x1="7" y1="2" x2="7" y2="22"></line><line x1="17" y1="2" x2="17" y2="22"></line><line x1="2" y1="12" x2="22" y2="12"></line><line x1="2" y1="7" x2="7" y2="7"></line><line x1="2" y1="17" x2="7" y2="17"></line><line x1="17" y1="17" x2="22" y2="17"></line><line x1="17" y1="7" x2="22" y2="7"></line></svg>`;

                    const fallbackDiv = `<div class="media-poster-thumb fallback-thumb" style="display:${posterUrl ? 'none' : 'flex'};align-items:center;justify-content:center;color:#6b7280;background:#181824;">${defaultIcon}</div>`;
                    const posterImg = posterUrl
                        ? `<img src="${posterUrl}" class="media-poster-thumb" alt="${item.title}" loading="lazy" onerror="this.style.display='none';if(this.nextElementSibling)this.nextElementSibling.style.display='flex';">${fallbackDiv}`
                        : fallbackDiv;

                    const epSub = isShows && item.episodes_played ? `<span>• ${item.episodes_played} ep</span>` : '';

                    const titleText = escapeHtml(item.title || '');
                    card.innerHTML = `
                        <div class="rank-badge ${rankClass}">#${rank}</div>
                        ${posterImg}
                        <div class="media-meta-col">
                            <div class="media-title-text" title="${titleText}">${titleText}</div>
                            <div class="media-sub-text">
                                <span class="stat-pill-sm">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="12" height="12"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
                                    ${formatDuration(item.seconds)}
                                </span>
                                <span>• ${item.plays} plays</span>
                                ${epSub}
                            </div>
                        </div>
                    `;
                    grid.appendChild(card);
                });
            }

            function renderPersonLeaderboard(items, isDirectors) {
                const grid = document.getElementById('leaderboard-grid');
                grid.innerHTML = '';

                if (!items || items.length === 0) {
                    grid.innerHTML = `<div style="grid-column: 1 / -1; padding: 40px; text-align: center; color: #9ca3af;">No viewing activity recorded for ${isDirectors ? 'directors' : 'actors'} in the selected window.</div>`;
                    return;
                }

                items.forEach((item, idx) => {
                    const rank = idx + 1;
                    let rankClass = '';
                    if (rank === 1) rankClass = 'gold';
                    else if (rank === 2) rankClass = 'silver';
                    else if (rank === 3) rankClass = 'bronze';

                    const card = document.createElement('div');
                    card.className = 'media-rank-card';
                    card.style.cursor = 'pointer';

                    if (item.person_id) {
                        card.addEventListener('click', () => { window.location.href = `/person?id=${item.person_id}`; });
                    }

                    const profileUrl = getPosterUrl(item.profile_path);
                    const nameText = escapeHtml(item.name || '');
                    const initial = item.name && item.name.length > 0 ? escapeHtml(item.name[0].toUpperCase()) : '?';
                    const fallbackAvatar = `<div class="person-avatar-thumb" style="display:${profileUrl ? 'none' : 'flex'};align-items:center;justify-content:center;color:#ffffff;background:linear-gradient(135deg, ${isDirectors ? '#0ea5e9, #6366f1' : '#8b5cf6, #ec4899'});font-weight:700;font-size:1.1rem;">${initial}</div>`;
                    const profileImg = profileUrl
                        ? `<img src="${profileUrl}" class="person-avatar-thumb" alt="${nameText}" loading="lazy" onerror="this.style.display='none';if(this.nextElementSibling)this.nextElementSibling.style.display='flex';">${fallbackAvatar}`
                        : fallbackAvatar;

                    const titlesText = item.titles_count ? `<span>• ${item.titles_count} ${item.titles_count === 1 ? 'title' : 'titles'}</span>` : '';
                    const roleText = item.top_role ? `<span>• ${escapeHtml(item.top_role)}</span>` : '';

                    card.innerHTML = `
                        <div class="rank-badge ${rankClass}">#${rank}</div>
                        ${profileImg}
                        <div class="media-meta-col">
                            <div class="media-title-text" title="${nameText}">${nameText}</div>
                            <div class="media-sub-text">
                                <span class="stat-pill-sm">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="12" height="12"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
                                    ${formatDuration(item.seconds)}
                                </span>
                                <span>• ${item.plays} plays</span>
                                ${titlesText}
                                ${roleText}
                            </div>
                        </div>
                    `;
                    grid.appendChild(card);
                });
            }

            function renderTrivia(trivia) {
                const grid = document.getElementById('trivia-grid');
                if (!grid) return;
                grid.innerHTML = '';

                if (!trivia) {
                    grid.innerHTML = `<div style="grid-column: 1 / -1; padding: 30px; text-align: center; color: #9ca3af;">Indexing catalog trivia...</div>`;
                    return;
                }

                // 1. The Familiar Face (Ubiquitous Actor)
                const u = trivia.ubiquitous_actor;
                const card1 = document.createElement('div');
                card1.className = 'trivia-card';
                if (u) {
                    const uPhoto = getPosterUrl(u.profile_path);
                    const uInitial = u.name ? u.name[0].toUpperCase() : '?';
                    const uAvatar = uPhoto
                        ? `<img src="${uPhoto}" class="trivia-person-thumb" alt="${u.name}" onerror="this.style.display='none';if(this.nextElementSibling)this.nextElementSibling.style.display='flex';"><div class="trivia-person-thumb" style="display:none;align-items:center;justify-content:center;color:#fff;background:linear-gradient(135deg,#0ea5e9,#6366f1);font-weight:700;">${uInitial}</div>`
                        : `<div class="trivia-person-thumb" style="display:flex;align-items:center;justify-content:center;color:#fff;background:linear-gradient(135deg,#0ea5e9,#6366f1);font-weight:700;">${uInitial}</div>`;

                    const samplePills = (u.sample_titles || []).map(t => `<span class="trivia-pill">${t}</span>`).join('');
                    card1.innerHTML = `
                        <div>
                            <div class="trivia-header">
                                <div class="trivia-badge-icon blue">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="20" height="20">
                                        <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon>
                                    </svg>
                                </div>
                                <div>
                                    <div class="trivia-type-label">The Familiar Face</div>
                                    <div class="trivia-title">Most Ubiquitous Actor</div>
                                </div>
                            </div>
                            <div class="trivia-body">
                                <div class="trivia-main-metric">
                                    ${uAvatar}
                                    <a href="/person?id=${u.person_id}" style="color:inherit;text-decoration:none;">${u.name}</a>
                                </div>
                                <div class="trivia-description">
                                    Appears across <strong>${u.title_count}</strong> distinct movies & shows in your collection.
                                </div>
                                <div class="trivia-pills-list">${samplePills}</div>
                            </div>
                        </div>
                    `;
                } else {
                    card1.innerHTML = `
                        <div class="trivia-header">
                            <div class="trivia-badge-icon blue">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="20" height="20">
                                    <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon>
                                </svg>
                            </div>
                            <div>
                                <div class="trivia-type-label">The Familiar Face</div>
                                <div class="trivia-title">Most Ubiquitous Actor</div>
                            </div>
                        </div>
                        <div class="trivia-body"><div class="trivia-description">Requires at least 2 titles with credited cast members in library.</div></div>
                    `;
                }
                grid.appendChild(card1);

                // 2. Dynamic Duo (Collaborator Pair)
                const c = trivia.collaborators;
                const card2 = document.createElement('div');
                card2.className = 'trivia-card';
                if (c) {
                    const samplePills = (c.shared_titles || []).map(t => `<span class="trivia-pill">${t}</span>`).join('');
                    card2.innerHTML = `
                        <div>
                            <div class="trivia-header">
                                <div class="trivia-badge-icon purple">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="20" height="20">
                                        <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
                                        <circle cx="9" cy="7" r="4"></circle>
                                        <path d="M23 21v-2a4 4 0 0 0-3-3.87"></path>
                                        <path d="M16 3.13a4 4 0 0 1 0 7.75"></path>
                                    </svg>
                                </div>
                                <div>
                                    <div class="trivia-type-label">Dynamic Duo</div>
                                    <div class="trivia-title">Top Collaborators</div>
                                </div>
                            </div>
                            <div class="trivia-body">
                                <div class="trivia-main-metric" style="font-size:1.15rem; flex-wrap:wrap; gap:6px;">
                                    <a href="/person?id=${c.person_a_id}" style="color:inherit;text-decoration:none;">${c.person_a_name}</a>
                                    <span style="color:#9ca3af;font-weight:400;font-size:0.9rem;">&</span>
                                    <a href="/person?id=${c.person_b_id}" style="color:inherit;text-decoration:none;">${c.person_b_name}</a>
                                </div>
                                <div class="trivia-description">
                                    Teamed up on <strong>${c.shared_title_count}</strong> titles (${c.person_a_role} & ${c.person_b_role}).
                                </div>
                                <div class="trivia-pills-list">${samplePills}</div>
                            </div>
                        </div>
                    `;
                } else {
                    card2.innerHTML = `
                        <div class="trivia-header">
                            <div class="trivia-badge-icon purple">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="20" height="20">
                                    <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path>
                                    <circle cx="9" cy="7" r="4"></circle>
                                </svg>
                            </div>
                            <div>
                                <div class="trivia-type-label">Dynamic Duo</div>
                                <div class="trivia-title">Top Collaborators</div>
                            </div>
                        </div>
                        <div class="trivia-body"><div class="trivia-description">Discovering collaborator pairings across catalog...</div></div>
                    `;
                }
                grid.appendChild(card2);

                // 3. The Great Crossover
                const x = trivia.crossover;
                const card3 = document.createElement('div');
                card3.className = 'trivia-card';
                if (x) {
                    const actorPills = (x.shared_actors || []).map(a => `<span class="trivia-pill">${a}</span>`).join('');
                    const linkA = x.title_a_is_show ? `/show?id=${x.title_a_id}` : `/details?id=${x.title_a_id}`;
                    const linkB = x.title_b_is_show ? `/show?id=${x.title_b_id}` : `/details?id=${x.title_b_id}`;
                    card3.innerHTML = `
                        <div>
                            <div class="trivia-header">
                                <div class="trivia-badge-icon amber">
                                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="20" height="20">
                                        <circle cx="18" cy="18" r="3"></circle>
                                        <circle cx="6" cy="6" r="3"></circle>
                                        <path d="M13 6h3a2 2 0 0 1 2 2v7"></path>
                                        <line x1="6" y1="9" x2="6" y2="21"></line>
                                    </svg>
                                </div>
                                <div>
                                    <div class="trivia-type-label">The Great Crossover</div>
                                    <div class="trivia-title">Largest Cast Overlap</div>
                                </div>
                            </div>
                            <div class="trivia-body">
                                <div class="trivia-main-metric" style="font-size:1.1rem; flex-wrap:wrap; gap:6px;">
                                    <a href="${linkA}" style="color:inherit;text-decoration:none;">${x.title_a_name}</a>
                                    <span style="color:#9ca3af;font-weight:400;font-size:0.85rem;">✕</span>
                                    <a href="${linkB}" style="color:inherit;text-decoration:none;">${x.title_b_name}</a>
                                </div>
                                <div class="trivia-description">
                                    Share <strong>${x.shared_actor_count}</strong> common cast members across both titles.
                                </div>
                                <div class="trivia-pills-list">${actorPills}</div>
                            </div>
                        </div>
                    `;
                } else {
                    card3.innerHTML = `
                        <div class="trivia-header">
                            <div class="trivia-badge-icon amber">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="20" height="20">
                                    <circle cx="18" cy="18" r="3"></circle>
                                    <circle cx="6" cy="6" r="3"></circle>
                                </svg>
                            </div>
                            <div>
                                <div class="trivia-type-label">The Great Crossover</div>
                                <div class="trivia-title">Largest Cast Overlap</div>
                            </div>
                        </div>
                        <div class="trivia-body"><div class="trivia-description">Scanning library for shared ensemble casts...</div></div>
                    `;
                }
                grid.appendChild(card3);

                // 4. Decade Time Machine
                const card4 = document.createElement('div');
                card4.className = 'trivia-card';
                const eras = trivia.eras || [];
                let eraRows = '';
                eras.forEach(e => {
                    if (e.percent > 0 || e.title_count > 0 || e.seconds > 0) {
                        eraRows += `
                            <div class="era-row">
                                <span class="era-label">${e.label}</span>
                                <div class="era-bar-track">
                                    <div class="era-bar-fill" style="width: ${e.percent}%;"></div>
                                </div>
                                <span class="era-value">${e.percent}%</span>
                            </div>
                        `;
                    }
                });

                card4.innerHTML = `
                    <div>
                        <div class="trivia-header">
                            <div class="trivia-badge-icon emerald">
                                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" width="20" height="20">
                                    <circle cx="12" cy="12" r="10"></circle>
                                    <polyline points="12 6 12 12 14 14"></polyline>
                                </svg>
                            </div>
                            <div>
                                <div class="trivia-type-label">Decade Time Machine</div>
                                <div class="trivia-title">Cinema Era Breakdown</div>
                            </div>
                        </div>
                        <div class="trivia-body">
                            <div class="era-list">
                                ${eraRows || '<div style="color:#9ca3af;font-size:0.8rem;">No era data available.</div>'}
                            </div>
                        </div>
                    </div>
                `;
                grid.appendChild(card4);
            }

            function renderUserTable(users) {
                const tbody = document.getElementById('user-table-body');
                tbody.innerHTML = '';

                if (!users || users.length === 0) {
                    tbody.innerHTML = `<tr><td colspan="5" style="text-align: center; padding: 30px; color: #9ca3af;">No viewer activity recorded.</td></tr>`;
                    return;
                }

                users.forEach((u, i) => {
                    const tr = document.createElement('tr');
                    const userName = escapeHtml(u.username || '');
                    const initial = u.username && u.username.length > 0 ? escapeHtml(u.username[0].toUpperCase()) : '?';
                    tr.innerHTML = `
                        <td style="color: #6b7280; font-weight: 700;">#${i + 1}</td>
                        <td>
                            <div style="display: flex; align-items: center; gap: 10px;">
                                <div class="user-avatar-initial">${initial}</div>
                                <span style="font-weight: 600; color: #f3f4f6;">${userName}</span>
                            </div>
                        </td>
                        <td style="font-weight: 600; color: #38bdf8;">${formatDuration(u.seconds)}</td>
                        <td>${u.plays}</td>
                        <td style="color: #9ca3af;">${formatRelativeDate(u.last_active)}</td>
                    `;
                    tbody.appendChild(tr);
                });
            }

            function renderLeaderboardView() {
                if (currentContentType === 'movies') {
                    renderLeaderboard(currentData.top_movies || [], false);
                } else if (currentContentType === 'shows') {
                    renderLeaderboard(currentData.top_shows || [], true);
                } else if (currentContentType === 'actors') {
                    renderPersonLeaderboard(currentData.top_actors || [], false);
                } else if (currentContentType === 'directors') {
                    renderPersonLeaderboard(currentData.top_directors || [], true);
                }
            }

            function refreshView() {
                updateKpis(currentData.overview);
                renderTrendChart(currentData.daily_trend);
                renderHourlyChart(currentData.hourly_distribution, currentData.overview.peak_hour);
                renderTrivia(currentData.trivia);
                renderLeaderboardView();
                renderUserTable(currentData.user_activity);
            }

            async function fetchAnalytics() {
                try {
                    const resp = await fetch(`/api/v1/admin/analytics?range=${currentRange}&sort=${currentSort}`);
                    if (!resp.ok) throw new Error('Network error');
                    currentData = await resp.json();
                    refreshView();
                } catch (e) {
                    console.error('Failed to update analytics:', e);
                }
            }

            // Range buttons listener
            document.querySelectorAll('#range-filter-group .filter-pill').forEach(btn => {
                btn.addEventListener('click', () => {
                    document.querySelectorAll('#range-filter-group .filter-pill').forEach(b => b.classList.remove('active'));
                    btn.classList.add('active');
                    currentRange = btn.getAttribute('data-range');
                    fetchAnalytics();
                });
            });

            // Content type toggle listener
            document.querySelectorAll('#content-type-group .toggle-btn').forEach(btn => {
                btn.addEventListener('click', () => {
                    document.querySelectorAll('#content-type-group .toggle-btn').forEach(b => b.classList.remove('active'));
                    btn.classList.add('active');
                    currentContentType = btn.getAttribute('data-type');
                    renderLeaderboardView();
                });
            });

            // Sort type toggle listener
            document.querySelectorAll('#sort-type-group .toggle-btn').forEach(btn => {
                btn.addEventListener('click', () => {
                    document.querySelectorAll('#sort-type-group .toggle-btn').forEach(b => b.classList.remove('active'));
                    btn.classList.add('active');
                    currentSort = btn.getAttribute('data-sort');
                    fetchAnalytics();
                });
            });

            // Initial render
            refreshView();
        })();
