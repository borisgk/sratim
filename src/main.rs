use anyhow::{Context, Result};
use axum::{
    Json as AxumJson, Router,
    body::Body,
    extract::{Json, Path, Query, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, Serialize};
use std::fs;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::fs::File;
use tokio::process::Child;
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

#[derive(Serialize)]
pub struct DashStartResponse {
    pub manifest_url: String,
}

#[derive(Deserialize)]
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

pub async fn start_dash(
    State(state): State<Arc<AppState>>,
    Json(params): Json<DashParams>,
) -> impl IntoResponse {
    // Simplified: just return static manifest URL.
    // In a real implementation we would spawn FFmpeg here using state.ffmpeg_process
    let _ = state;
    let _ = params;

    let response = DashStartResponse {
        manifest_url: "/dash/manifest.mpd".to_string(),
    };
    AxumJson(response)
}

pub async fn get_dash_file(
    State(state): State<Arc<AppState>>,
    Path(path): Path<String>,
) -> impl IntoResponse {
    // path will be something like "manifest.mpd" or "chunk_...m4s"
    let filename = path.strip_prefix("/dash/").unwrap_or(&path);
    let file_path = state.dash_temp_dir.join(filename);
    if !file_path.starts_with(&state.dash_temp_dir) {
        return StatusCode::FORBIDDEN.into_response();
    }
    match File::open(&file_path).await {
        Ok(file) => {
            let stream = ReaderStream::new(file);
            let content_type = if filename.ends_with(".mpd") {
                "application/dash+xml"
            } else if filename.ends_with(".mp4") {
                "video/mp4"
            } else {
                "video/iso.segment"
            };
            Response::builder()
                .header("Content-Type", content_type)
                .header("Cache-Control", "no-cache")
                .body(Body::from_stream(stream))
                .unwrap()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

pub async fn get_subtitles(
    State(state): State<Arc<AppState>>,
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

    let shared_state = Arc::new(AppState {
        movies_dir: movies_dir.clone(),
        dash_temp_dir,
        ffmpeg_process: Arc::new(Mutex::new(None)),
    });

    let app = Router::new()
        .route("/api/dash/start", get(start_dash))
        .route("/dash/*file", get(get_dash_file))
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
