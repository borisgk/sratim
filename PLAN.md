# SRATIM — Project Plan & Status

> Last updated: see git log

---

## 📽️ What It Is

A self-hosted, Rust-powered media streaming server (Hebrew for "Movies") — think a lightweight, personal Plex/Jellyfin. It streams video via **Media Source Extensions (MSE)** with zero transcoding for perfect quality.

---

## ✅ What's Already Built & Working

### Backend (Rust / Axum)

| Module | Description | Status |
|---|---|---|
| `main.rs` | Router, app init, background scanner startup | ✅ Done |
| `auth.rs` | JWT auth (cookies), bcrypt passwords, user CRUD | ✅ Done |
| `db.rs` | Turso/libSQL metadata DB with schema migrations | ✅ Done |
| `scanner.rs` | Background library scanner (Movies + TV Shows) | ✅ Done |
| `metadata.rs` | TMDB API integration, poster downloads, filename cleanup | ✅ Done |
| `routes/video.rs` | File listing, metadata probe, `/api/stream`, subtitles, lookup | ✅ Done |
| `routes/library.rs` | Library CRUD, filesystem browser, content serving, rescan | ✅ Done |
| `routes/ui.rs` | Full SSR rendering (index, player, TV mode, share handler) | ✅ Done |
| `streaming/process.rs` | FFmpeg spawning, keyframe probing, ProcessStream wrapper | ✅ Done |

### Frontend

| Feature | Status |
|---|---|
| SSR templates (Askama) for index, player, TV index, TV player | ✅ Done |
| Custom MSE player with seeking, audio & subtitle track selection | ✅ Done |
| Google Cast (Chromecast) support | ✅ Done |
| TV remote-friendly interface (`tv.js`, `tv.css`) | ✅ Done |
| Shareable links (with token-based auth for guests) | ✅ Done |
| Admin panel: users, libraries, rescan | ✅ Done |
| Profile page (change password) | ✅ Done |
| Filesystem browser for library path picker | ✅ Done |

---

## ⚠️ Known Issues / Tech Debt

1. ~~**Hardcoded JWT secret** — `JWT_SECRET` in `auth.rs` is a static byte string. Should come from an env var or config file.~~ ✅ Fixed: moved to `config.toml`.
2. ~~**TMDB token exposed in source** — `DEFAULT_TMDB_ACCESS_TOKEN` is committed in `models.rs` and duplicated in `config.toml`.~~ ✅ Fixed: constant removed, `config.toml` is the sole source.
3. **`scratch.rs`** — Leftover test/scratch file at the project root; should be removed.
4. ~~**Test artifacts committed** — `frontend/Movie's.mp4`, `cookies.txt`, and `tmdb_response.json` should be removed from the repo.~~ ✅ Fixed: files deleted and patterns added to `.gitignore`.
5. ~~**Dead `ffmpeg_process` field** — `ffmpeg_process: Arc<Mutex<Option<Child>>>` lives in `AppState` but is unused by the actual streaming path; should be removed.~~ ✅ Fixed: removed along with the dead `dash_temp_dir` field.
6. ~~**Single `DbClient` connection** — Turso's `Connection` is held in a single non-`Send`-safe struct; concurrent writes could bottleneck under load.~~ ✅ Fixed: `DbClient` now holds only `Database`; each method opens a fresh short-lived connection.

---

## 🚀 Next Steps

### 🔧 Polish & Fixes (Low effort, high impact)

- [x] Move JWT secret and TMDB token to config only (security hardening)
- [x] Delete `scratch.rs`, `cookies.txt`, `tmdb_response.json` from the repo
- [x] Remove the unused `ffmpeg_process` and `dash_temp_dir` fields from `AppState`
- [x] Add `.gitignore` entries for runtime state files: `metadata.db`, `users.json`, `libraries.json`
- [ ] Remove `scratch.rs` from the repo

### 🎬 Feature: Watch History / Continue Watching

- Store playback progress (path + timestamp + user) in the DB
- Expose a "Continue Watching" row on the home screen
- Requires a new `watch_progress` table with columns: `username`, `path`, `position`, `updated_at`

### 🔍 Feature: Search

- A search bar on the index page filtering titles from the metadata DB
- New `/api/search?q=` endpoint with a `LIKE` query against the `metadata` table
- Could be rendered inline on the existing index template (no new page needed)

### 📅 Feature: Recently Added

- The `added_at` column already exists in the DB — no schema changes needed
- Add a "Recently Added" section/row on the home page, driven by a `/api/recently-added` endpoint

### 📺 TV UI Enhancements

- The TV interface currently lacks the metadata lookup and share options available in the desktop UI
- Improve focus/highlight animation on TV grid cards
- Add a "Recently Added" row to the TV home screen

### 🔐 Multi-user Improvements

- Per-user watch history (the DB currently has no `username` column on any progress table)
- Role-based library visibility: ability to hide specific libraries from non-admin users
- Consider migrating `users.json` storage into the SQLite DB for consistency

### 🛠️ DevOps / Deployment

- `build.rs`, `build_number.txt`, `sratim.service`, and `deploy.sh` are already in place
- Flesh out the `.github/` CI workflow: automated build + test on push
- Consider Docker packaging for easier self-hosted deployment
