# SRATIM 🎬
### A Modern, High-Performance Movie Streamer

Sratim (Hebrew for "Movies") is a powerful, lightweight media server built with Rust, designed for high-fidelity movie streaming directly to your web browser. It uses **Media Source Extensions (MSE)** to deliver fragmented MP4 streams with zero quality loss.

---

## ✨ Key Features

- ⚡ **Direct Stream Copy**: Streams video data directly from the source file (H.264/HEVC) without transcoding, ensuring 100% original quality and minimal CPU usage.
- 🍏 **Smart Compatibility**: Automatically detects codec (H.264 vs HEVC) and configures the MSE player for Apple/Safari support (`hvc1`) or standard AVC (`avc1`).
- 📂 **Auto-Discovery**: Automatically scans your `movies` directory for video files and builds a navigable library.
- 🎨 **Premium UI**: A sleek, modern frontend built with Inter & Outfit typography, featuring glassmorphism and smooth animations.
- ⏩ **Advanced Player**: Custom-built HTML5 MSE player with instant seeking, duration tracking, and robust buffering management.

## 🛠 Tech Stack

- **Backend**: [Rust](https://www.rust-lang.org/) with [Axum](https://github.com/tokio-rs/axum) and [Tokio](https://tokio.rs/) for high-concurrency performance.
- **Media Engine**: [FFmpeg](https://ffmpeg.org/) & [ffprobe](https://ffmpeg.org/ffprobe.html) for stream segmentation and metadata probing.
- **Frontend**: Vanilla JavaScript (MSE API) and CSS3 for a lean, fast, and beautiful user experience.

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

## 📝 License

This project is licensed under the GNU GPL v3 - see the LICENSE file for details.
