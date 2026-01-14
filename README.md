# SRATIM 🎬
### A Modern, High-Performance Movie Streamer

Sratim (Hebrew for "Movies") is a powerful, lightweight media server built with Rust, designed for seamless movie streaming directly to your web browser. It features **real-time transcoding**, allowing you to play almost any video format (including MKV and AVI) without manual conversion.

---

## ✨ Key Features

- ⚡ **Real-Time Transcoding**: Automatically converts incompatible codecs to browser-friendly H.264/AAC on the fly using FFmpeg.
- 🍏 **Apple Silicon Optimized**: Uses `h264_videotoolbox` hardware acceleration on macOS for near-zero CPU impact during transcoding.
- 📁 **Auto-Discovery**: Automatically scans your `movies` directory for video files and builds a navigable library.
- 🎨 **Premium UI**: A sleek, modern frontend built with Inter & Outfit typography, featuring glassmorphism and smooth animations.
- ⏩ **Advanced Player Controls**: Custom-built HTML5 player with seekable transcoded streams, duration tracking, and fullscreen support.
- 📦 **Effortless Deployment**: Includes a specialized `deploy.sh` for easy rsync and remote building.

## 🛠 Tech Stack

- **Backend**: [Rust](https://www.rust-lang.org/) with [Axum](https://github.com/tokio-rs/axum) and [Tokio](https://tokio.rs/) for high-concurrency performance.
- **Media Engine**: [FFmpeg](https://ffmpeg.org/) & [ffprobe](https://ffmpeg.org/ffprobe.html) for robust stream processing.
- **Frontend**: Vanilla JavaScript and CSS3 for a lean, fast, and beautiful user experience.

---

## 🚀 Getting Started

### Prerequisites

- **Rust**: [Install Rust](https://www.rust-lang.org/tools/install) (Edition 2024).
- **FFmpeg**: Ensure `ffmpeg` and `ffprobe` are in your system PATH.

### Installation

1. **Clone the repository**:
   ```bash
   git clone <repository-url>
   cd sratim
   ```

2. **Add your movies**:
   Place your MKV, MP4, or AVI files in the `movies/` directory (created automatically on first run).
   ```bash
   mkdir movies
   # Copy your movies here
   ```

3. **Run the server**:
   ```bash
   cargo run --release
   ```

4. **Access the library**:
   Open your browser and navigate to `http://localhost:3000`.

---

## 🏗 Deployment

The project includes a `deploy.sh` script to simplify deployment to remote servers:

```bash
./deploy.sh <user@remote-host> <target-directory>
```

This will sync the source code and trigger a release build on the destination.

---

## 📝 License

This project is licensed under the MIT License - see the LICENSE file for details.
