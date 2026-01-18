use anyhow::{Context, Result};
use axum::{
    Router,
    body::Body,
    extract::{Json, Query, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
// use tokio::fs::File; // Removed
use tokio::process::Child;
use tokio::sync::Mutex;
use tokio_util::io::ReaderStream;
use tower::ServiceBuilder;
use tower_http::{cors::CorsLayer, services::ServeDir, set_header::SetResponseHeaderLayer};

// --- Config ---

#[derive(Debug, Deserialize, Clone)]
pub struct AppConfig {
    #[serde(default = "default_movies_dir")]
    pub movies_dir: PathBuf,
    #[serde(default = "default_frontend_dir")]
    pub frontend_dir: PathBuf,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_host")]
    pub host: String,
}

fn default_movies_dir() -> PathBuf {
    PathBuf::from("movies")
}

fn default_frontend_dir() -> PathBuf {
    PathBuf::from("frontend")
}

fn default_port() -> u16 {
    3000
}

fn default_host() -> String {
    "0.0.0.0".to_string()
}

impl AppConfig {
    pub fn load() -> Result<Self> {
        let config_paths = [
            PathBuf::from("config.toml"),
            PathBuf::from("/usr/local/etc/sratim/config.toml"),
            PathBuf::from("/etc/sratim/config.toml"),
        ];

        for path in &config_paths {
            if path.exists() {
                println!("Loading configuration from: {:?}", path);
                let content = fs::read_to_string(path)
                    .with_context(|| format!("Failed to read config file: {:?}", path))?;
                let config: AppConfig = toml::from_str(&content)
                    .with_context(|| format!("Failed to parse TOML in: {:?}", path))?;
                return Ok(config);
            }
        }

        println!("No config file found, using default settings.");
        Ok(Self::default_settings())
    }

    fn default_settings() -> Self {
        Self {
            movies_dir: default_movies_dir(),
            frontend_dir: default_frontend_dir(),
            port: default_port(),
            host: default_host(),
        }
    }
}

// --- State ---

#[derive(Clone)]
pub struct AppState {
    pub movies_dir: PathBuf,
    pub dash_temp_dir: PathBuf,
    pub ffmpeg_process: Arc<Mutex<Option<Child>>>,
}

// --- Models ---

// DashStartResponse removed

#[derive(Deserialize, Clone)]
pub struct DashParams {
    pub path: String,
    #[serde(default)]
    pub start: f64,
    #[serde(rename = "audioTrack")]
    pub audio_track: Option<usize>,
}

#[derive(Deserialize)]
pub struct SubtitleParams {
    pub path: String,
    pub index: usize,
}

// --- Handlers ---

#[derive(Deserialize)]
pub struct ListParams {
    #[serde(default)]
    pub path: String,
}

#[derive(Serialize)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    #[serde(rename = "type")]
    pub entry_type: String, // "folder" or "file"
}

pub async fn list_files(
    State(state): State<AppState>,
    Query(params): Query<ListParams>,
) -> impl IntoResponse {
    let mut abs_path = state.movies_dir.clone();
    if !params.path.is_empty() {
        abs_path.push(&params.path);
    }

    // Security check: ensure we didn't escape movies_dir
    let Ok(canonical_path) = abs_path.canonicalize() else {
        // If path doesn't exist or other error
        return (StatusCode::NOT_FOUND, Json(Vec::<FileEntry>::new())).into_response();
    };

    // We also need the canonical movies dir to check prefix
    let Ok(canonical_root) = state.movies_dir.canonicalize() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };

    if !canonical_path.starts_with(&canonical_root) {
        return StatusCode::FORBIDDEN.into_response();
    }

    let mut entries = Vec::new();

    if let Ok(mut read_dir) = tokio::fs::read_dir(canonical_path).await {
        while let Ok(Some(entry)) = read_dir.next_entry().await {
            let file_name = entry.file_name().to_string_lossy().to_string();
            // Skip hidden files
            if file_name.starts_with('.') {
                continue;
            }

            let file_type = entry.file_type().await.ok();
            let is_dir = file_type.map(|t| t.is_dir()).unwrap_or(false);
            let is_file = file_type.map(|t| t.is_file()).unwrap_or(false);

            let mut rel_path = params.path.clone();
            if !rel_path.is_empty() && !rel_path.ends_with('/') {
                rel_path.push('/');
            }
            rel_path.push_str(&file_name);
            // Ensure no leading slash for relative paths if possible, or keep inconsistent?
            // Frontend sends path="" for root.
            // If we have "Action/movie.mp4", that's what we want.
            // If params.path was "Action", rel_path becomes "Action/movie.mp4"

            if is_dir {
                entries.push(FileEntry {
                    name: file_name,
                    path: rel_path,
                    entry_type: "folder".to_string(),
                });
            } else if is_file {
                // Filter extensions
                if let Some(ext) = std::path::Path::new(&file_name)
                    .extension()
                    .and_then(|s| s.to_str())
                {
                    match ext.to_lowercase().as_str() {
                        "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv" => {
                            entries.push(FileEntry {
                                name: file_name,
                                path: rel_path,
                                entry_type: "file".to_string(),
                            });
                        }
                        _ => {}
                    }
                }
            }
        }
    }

    // Sort: Folders first, then files. Both alphabetical.
    entries.sort_by(|a, b| {
        if a.entry_type == b.entry_type {
            a.name.to_lowercase().cmp(&b.name.to_lowercase())
        } else {
            // Folders ("folder") < Files ("file") ? No, "folder" > "file" alphabetically.
            // We want folders first.
            if a.entry_type == "folder" {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            }
        }
    });

    Json(entries).into_response()
}

#[derive(Deserialize)]
pub struct StreamParams {
    pub path: String,
    #[serde(default)]
    pub start: f64,
}

// Wrapper to keep the child process alive while streaming
pub struct ProcessStream {
    stream: ReaderStream<tokio::process::ChildStdout>,
    _child: Child,
}

impl futures_core::Stream for ProcessStream {
    type Item = std::io::Result<axum::body::Bytes>;

    fn poll_next(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        std::pin::Pin::new(&mut self.stream).poll_next(cx)
    }
}

// Separate clean probe for video codec
async fn probe_video_codec(path: &std::path::Path) -> String {
    let output = tokio::process::Command::new("ffprobe")
        .args(&[
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=codec_name",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "h264".to_string(),
    }
}

// Separate clean probe for audio existence
async fn probe_has_audio(path: &std::path::Path) -> bool {
    let output = tokio::process::Command::new("ffprobe")
        .args(&[
            "-v",
            "error",
            "-select_streams",
            "a",
            "-show_entries",
            "stream=codec_type",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .output()
        .await;

    match output {
        Ok(out) if out.status.success() => !out.stdout.is_empty(),
        _ => false,
    }
}

// Separate clean probe for duration
async fn probe_duration(path: &std::path::Path) -> Option<f64> {
    let output = tokio::process::Command::new("ffprobe")
        .args(&[
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
        ])
        .arg(path)
        .output()
        .await
        .ok()?;

    if output.status.success() {
        let duration_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
        duration_str.parse::<f64>().ok()
    } else {
        None
    }
}

pub async fn stream_video(
    State(state): State<AppState>,
    Query(params): Query<StreamParams>,
) -> Response {
    let abs_path = state.movies_dir.join(&params.path);
    if !abs_path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    // Detect codec & audio & duration
    let codec_name = probe_video_codec(&abs_path).await;
    let has_audio = probe_has_audio(&abs_path).await;
    let duration = probe_duration(&abs_path).await.unwrap_or(0.0);

    println!(
        "Detected for {}: Codec={}, Audio={}, Duration={:.2}s",
        params.path, codec_name, has_audio, duration
    );

    let mut args = vec![
        "-ss".to_string(),
        params.start.to_string(),
        "-i".to_string(),
        abs_path.to_string_lossy().to_string(),
        "-map".to_string(),
        "0:v:0".to_string(),
        "-c:v".to_string(),
        "copy".to_string(),
    ];

    // Only add hvc1 tag if it's HEVC.
    if codec_name == "hevc" {
        args.push("-tag:v".to_string());
        args.push("hvc1".to_string());
    }

    if has_audio {
        args.extend_from_slice(&[
            "-map".to_string(),
            "0:a:0".to_string(),
            "-c:a".to_string(),
            "aac".to_string(),
            "-ac".to_string(),
            "2".to_string(),
        ]);
    }

    args.extend_from_slice(&[
        "-movflags".to_string(),
        "frag_keyframe+empty_moov+default_base_moof".to_string(),
        "-f".to_string(),
        "mp4".to_string(),
        "pipe:1".to_string(),
    ]);

    println!("[stream] Spawning ffmpeg: {:?}", args);

    let mut command = tokio::process::Command::new("ffmpeg");
    command
        .args(&args)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    match command.spawn() {
        Ok(mut child) => {
            let stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();

            tokio::spawn(async move {
                use tokio::io::{AsyncBufReadExt, BufReader};
                let mut reader = BufReader::new(stderr);
                let mut line = String::new();
                while let Ok(n) = reader.read_line(&mut line).await {
                    if n == 0 {
                        break;
                    }
                    eprint!("[ffmpeg] {}", line);
                    line.clear();
                }
            });

            let stream = ReaderStream::new(stdout);
            let process_stream = ProcessStream {
                stream,
                _child: child,
            };

            Response::builder()
                .header("Content-Type", "video/mp4")
                .header("Cache-Control", "no-cache")
                .header("X-Video-Codec", codec_name) // Signal codec to frontend
                .header("X-Has-Audio", if has_audio { "true" } else { "false" }) // Signal audio presence
                .header("X-Video-Duration", duration.to_string()) // Signal duration
                .body(Body::from_stream(process_stream))
                .unwrap()
        }
        Err(e) => {
            eprintln!("Failed to spawn ffmpeg: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

pub async fn get_subtitles(
    State(state): State<AppState>,
    Query(params): Query<SubtitleParams>,
) -> impl IntoResponse {
    // Stub: not implemented
    let _ = state;
    let _ = params;
    StatusCode::NOT_FOUND.into_response()
}

// --- Main ---

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let config = AppConfig::load().expect("Failed to load configuration");

    let movies_dir = config.movies_dir.clone();
    if !movies_dir.exists() {
        std::fs::create_dir_all(&movies_dir).expect("Failed to create movies directory");
    }

    let dash_temp_dir = std::env::temp_dir().join("sratim_dash");
    std::fs::create_dir_all(&dash_temp_dir).expect("Failed to create dash temp directory");

    let shared_state = AppState {
        movies_dir: movies_dir.clone(),
        dash_temp_dir,
        ffmpeg_process: Arc::new(Mutex::new(None)),
    };

    let app = Router::new()
        .route("/api/movies", get(list_files))
        .route("/api/stream", get(stream_video))
        .route("/api/subtitles", get(get_subtitles))
        .nest_service("/content", ServeDir::new(&movies_dir))
        .fallback_service(
            ServiceBuilder::new()
                .layer(SetResponseHeaderLayer::overriding(
                    header::CACHE_CONTROL,
                    HeaderValue::from_static(
                        "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
                    ),
                ))
                .service(ServeDir::new(&config.frontend_dir)),
        )
        .layer(CorsLayer::permissive())
        .with_state(shared_state);

    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid host/port");

    println!("Server running on http://{}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
