# Sratim (סרטים)

A modern, ultra-lightweight, and high-performance media server written in **pure Zig (0.17.0)** with **zero C/libc dependencies**.

Sratim automatically scans your movie and TV show libraries, fetches rich metadata and artwork from TMDb, and streams media directly to web browsers using custom, native in-process video slicing and audio transcoding.

---

## ⚡ Core Advantages

- **Pure Zig & Zero Runtime Dependencies**:
  Sratim compiles into a single, self-contained static binary. There is **no need for ffmpeg**, **no external database server** (SQLite, PostgreSQL, etc.), and **no libc linkage**. Deploying Sratim is as simple as running a single executable.
- **High-Performance In-Memory Database with Durability**:
  All catalog and user data are served directly from fast in-memory tables (`zembed`), delivering sub-millisecond API and catalog response times. Durability is guaranteed through asynchronous JSON snapshots (`sratim.json`, `logs.json`) and write-ahead logging (WAL).
- **Native In-Process Streaming & Audio Transcoding**:
  Sratim features a custom Matroska (MKV) parser and video slicer that generates fragmented MP4 (fMP4) streams on-the-fly with zero-copy video passthrough. Includes pure-Zig audio decoders for **AC-3**, **E-AC-3**, and **DTS** that downmix and transcode multi-channel audio directly to stereo AAC-LC in memory.
- **Strict Content Safety (Non-Destructive)**:
  Sratim prioritizes the safety of your storage. Deleting libraries, unlinking metadata, or clearing catalog items **never deletes or alters files or folders on disk**.
- **Smart Catalog & Rich Metadata**:
  - Automatically fetches posters, backdrops, overviews, release years, and cast/crew details from The Movie Database (TMDb).
  - Actor and director filmography browsing with local library badges.
  - **Natural Alphabetical Sorting**: Library views automatically ignore leading articles (*"The"*, *"A"*, *"An"*) so titles sort intuitively by their core names.
- **Multi-User & Granular Access Control**:
  - Multi-user authentication with salt-hashed passwords and session management.
  - Dedicated Admin Panel for managing users, monitoring storage metrics, and controlling media libraries.
  - Independent playback progress tracking and resume-watching per user.
- **Effortless Cross-Compilation**:
  Leveraging Zig's native toolchain, Sratim cross-compiles without external sysroots or containers for `x86_64-linux`, `aarch64-linux` (e.g., Raspberry Pi), `x86_64-windows`, and `aarch64-macos`.

---

## 📢 Community & Updates

Join our Telegram channel to stay updated with the latest releases, feature updates, and discussions:  
👉 **[Sratim Server Channel](https://t.me/sratimserver)**

---

## 🚀 Quick Install (Linux Systemd)

You can automatically install Sratim on any systemd-based Linux distribution (Debian, Ubuntu, Arch Linux, etc.) using our universal installation script:

```bash
curl -fsSL https://raw.githubusercontent.com/borisgk/sratim/main/scripts/install.sh | sudo bash
```

### What the installer does:
1. Downloads the latest release binary to `/usr/local/bin/sratim`.
2. Generates a default configuration file at `/etc/sratim/config.json`.
3. Prepares the persistent data directory at `/var/lib/sratim/`.
4. Installs and starts the `sratim.service` systemd daemon under a dedicated dynamic system user.

---

## ⚙️ Configuration

The server configuration resides in `config.json` (at `/etc/sratim/config.json` in production, or `./config.json` for local development):

```json
{
  "port": 8000,
  "tmdb_access_token": "YOUR_TMDB_API_READ_ACCESS_TOKEN",
  "tmdb_proxy": ""
}
```

- **`port`**: HTTP port the server listens on (default: `8000`).
- **`tmdb_access_token`**: TMDb v4 Read Access Token (JWT) used to fetch movie/show metadata and artwork.
- **`tmdb_proxy`**: *(Optional)* HTTP proxy URL for environments where TMDb access is restricted.

Restart the systemd service after editing production configuration:
```bash
sudo systemctl restart sratim
```

---

## 🛠️ Managing the Server

Manage the service using standard `systemctl` commands:

```bash
# Check service status
systemctl status sratim

# View real-time logs
journalctl -u sratim -f

# Restart daemon
sudo systemctl restart sratim
```

---

## 💻 Building from Source & Local Development

### Requirements
- **Zig 0.17.0**

### 1. Build Locally (Debug)
```bash
git clone https://github.com/borisgk/sratim.git
cd sratim
zig build
```

The compiled binary will be placed at `zig-out/bin/sratim`.

### 2. Build for Production (ReleaseFast)
```bash
zig build -Doptimize=ReleaseFast
```

### 3. Cross-Compilation Examples
Because Sratim has zero C/libc dependencies, you can cross-compile for other architectures directly from any host machine without installing additional toolchains:

```bash
# Linux 64-bit (x86_64)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast

# Raspberry Pi / Linux ARM64 (aarch64)
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast

# Windows 64-bit
zig build -Dtarget=x86_64-windows -Doptimize=ReleaseFast

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
```

### 4. Running Tests
```bash
zig build test --summary all
```

### Development Mode & Safe Paths
When a `config.json` exists in your working directory, Sratim automatically enters **Development Mode**. It stores all database snapshots (`sratim.json`), WAL logs (`sratim.wal`), and telemetry in the local working directory rather than touching `/var/lib/sratim/`.

---

## 📐 Architecture

For a detailed technical overview of modules, in-memory tables, streaming pipelines, and coding conventions, see [`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
