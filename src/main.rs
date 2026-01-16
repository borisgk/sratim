use axum::{
    Router,
    extract::{Query, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Json},
    routing::get,
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use tower::ServiceBuilder;
use tower_http::{cors::CorsLayer, services::ServeDir, set_header::SetResponseHeaderLayer};

mod config;
mod transcode;

use config::AppConfig;

#[derive(Clone)]
struct AppState {
    movies_dir: PathBuf,
    transcode_manager: Arc<TranscodeManager>,
}

#[derive(Hash, PartialEq, Eq, Clone, Debug)]
enum TaskKey {
    Stream(PathBuf),
    Subtitles(PathBuf, usize),
}

struct TranscodeManager {
    tasks: std::sync::Mutex<std::collections::HashMap<TaskKey, tokio::task::AbortHandle>>,
}

impl TranscodeManager {
    fn new() -> Self {
        Self {
            tasks: std::sync::Mutex::new(std::collections::HashMap::new()),
        }
    }

    fn register(&self, key: TaskKey, handle: tokio::task::AbortHandle) {
        let mut tasks = self.tasks.lock().unwrap();
        if let Some(old) = tasks.insert(key.clone(), handle) {
            println!("[manager] Aborting previous task for {:?}", key);
            old.abort();
        }
    }

    fn unregister(&self, key: &TaskKey) {
        let mut tasks = self.tasks.lock().unwrap();
        tasks.remove(key);
    }
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum MediaNode {
    Folder { name: String, path: String },
    File { name: String, path: String },
}

#[derive(Deserialize)]
struct ListParams {
    path: Option<String>,
}

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::fmt::init();

    // Load configuration
    let config = AppConfig::load().expect("Failed to load configuration");

    let movies_dir = config.movies_dir.clone();
    if !movies_dir.exists() {
        std::fs::create_dir_all(&movies_dir).expect("Failed to create movies directory");
        println!("Created movies directory: {:?}", movies_dir);
    }

    let shared_state = Arc::new(AppState {
        movies_dir: movies_dir.clone(),
        transcode_manager: Arc::new(TranscodeManager::new()),
    });

    // Router
    let app = Router::new()
        .route("/api/movies", get(list_movies))
        // Serve the movies directory directly so browsers can request ranges
        .nest_service("/content", ServeDir::new(&movies_dir))
        .route("/api/transcode", get(transcode_movie))
        .route("/api/metadata", get(get_metadata))
        .route("/api/subtitles", get(extract_subtitles))
        // Serve the frontend with cache-disabling headers
        .fallback_service(
            ServiceBuilder::new()
                .layer(SetResponseHeaderLayer::overriding(
                    header::CACHE_CONTROL,
                    HeaderValue::from_static(
                        "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
                    ),
                ))
                .layer(SetResponseHeaderLayer::overriding(
                    header::PRAGMA,
                    HeaderValue::from_static("no-cache"),
                ))
                .layer(SetResponseHeaderLayer::overriding(
                    header::EXPIRES,
                    HeaderValue::from_static("0"),
                ))
                .service(ServeDir::new(&config.frontend_dir)),
        )
        .layer(CorsLayer::permissive())
        .with_state(shared_state);

    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid host/port in configuration");

    println!("Server running on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscodeParams {
    path: String,
    start: Option<f64>,
    audio_track: Option<usize>,
}

#[derive(Deserialize)]
struct SubtitleParams {
    path: String,
    index: usize,
}

async fn get_metadata(
    State(state): State<Arc<AppState>>,
    Query(params): Query<TranscodeParams>,
) -> impl IntoResponse {
    let path = state.movies_dir.join(&params.path);

    if !path.exists() {
        return axum::http::StatusCode::NOT_FOUND.into_response();
    }

    let transcoder = crate::transcode::Transcoder::new(path);
    match transcoder.get_metadata().await {
        Ok(info) => Json(info).into_response(),
        Err(e) => {
            eprintln!("Metadata failed: {}", e);
            axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn transcode_movie(
    State(state): State<Arc<AppState>>,
    Query(params): Query<TranscodeParams>,
) -> impl IntoResponse {
    let path = state.movies_dir.join(&params.path);

    if !path.exists() {
        return axum::http::StatusCode::NOT_FOUND.into_response();
    }

    // Use our custom transcoder
    // Note: In a real app, strict path validation is needed to prevent directory traversal
    let transcoder = crate::transcode::Transcoder::new(path.clone());

    match transcoder.stream(params.start, params.audio_track).await {
        Ok((mut rx, transcode_task_handle)) => {
            let key = TaskKey::Stream(path);
            let manager = Arc::clone(&state.transcode_manager);
            let key_clone = key.clone();

            let _cleanup_task = tokio::spawn(async move {
                // Wrapper to clean up on drop/panic
                let _cleanup = scopeguard::guard((manager, key_clone), |(m, k)| {
                    m.unregister(&k);
                });

                // This task just needs to exist to clean up the manager when the stream ends
                // We'll use a standard loop that ends when the manager unregisters us
                // or the response stream finishes.
                tokio::time::sleep(tokio::time::Duration::from_secs(3600 * 4)).await; // 4 hours max
            });

            // Register the ACTUAL transcode task for abortion
            state.transcode_manager.register(key, transcode_task_handle);

            // Create a stream from the receiver
            let stream = async_stream::stream! {
                while let Some(bytes) = rx.recv().await {
                    yield Ok::<_, std::io::Error>(axum::body::Bytes::from(bytes));
                }
            };

            axum::response::Response::builder()
                .header("Content-Type", "video/mp4")
                .header("Accept-Ranges", "none")
                .body(axum::body::Body::from_stream(stream))
                .unwrap()
        }
        Err(e) => {
            eprintln!("Failed to start transcoder: {}", e);
            axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn extract_subtitles(
    State(state): State<Arc<AppState>>,
    Query(params): Query<SubtitleParams>,
) -> impl IntoResponse {
    let path = state.movies_dir.join(&params.path);

    if !path.exists() {
        return axum::http::StatusCode::NOT_FOUND.into_response();
    }

    let transcoder = crate::transcode::Transcoder::new(path.clone());

    match transcoder.subtitles(params.index).await {
        Ok((mut rx, transcode_task_handle)) => {
            let key = TaskKey::Subtitles(path, params.index as usize);

            // Register the ACTUAL transcode task for abortion
            state.transcode_manager.register(key, transcode_task_handle);

            let stream = async_stream::stream! {
                while let Some(bytes) = rx.recv().await {
                    yield Ok::<_, std::io::Error>(axum::body::Bytes::from(bytes));
                }
            };

            axum::response::Response::builder()
                .header("Content-Type", "text/vtt")
                .header("Accept-Ranges", "none")
                .body(axum::body::Body::from_stream(stream))
                .unwrap()
        }
        Err(e) => {
            eprintln!("Failed to extract subtitles: {}", e);
            axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn list_movies(
    State(state): State<Arc<AppState>>,
    Query(params): Query<ListParams>,
) -> impl IntoResponse {
    let relative_path = params.path.unwrap_or_default();
    let abs_path = state.movies_dir.join(&relative_path);

    // Security check: ensure path is within movies_dir
    if !abs_path.starts_with(&state.movies_dir) {
        return (StatusCode::FORBIDDEN, "Access denied").into_response();
    }

    if !abs_path.exists() || !abs_path.is_dir() {
        return (StatusCode::NOT_FOUND, "Folder not found").into_response();
    }

    let mut nodes = Vec::new();
    if let Ok(entries) = std::fs::read_dir(abs_path) {
        for entry in entries.filter_map(|e| e.ok()) {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            let node_rel_path = path.strip_prefix(&state.movies_dir).unwrap_or(&path);
            let url_path = node_rel_path.to_string_lossy().replace('\\', "/");

            if path.is_dir() {
                nodes.push(MediaNode::Folder {
                    name,
                    path: url_path,
                });
            } else if path.is_file() {
                if let Some(ext) = path.extension() {
                    let ext_str = ext.to_string_lossy().to_lowercase();
                    if ["mkv", "mp4", "webm", "avi", "mov"].contains(&ext_str.as_str()) {
                        nodes.push(MediaNode::File {
                            name,
                            path: url_path,
                        });
                    }
                }
            }
        }
    }

    // Sort: Folders first, then alphabetically
    nodes.sort_by(|a, b| {
        let a_is_folder = matches!(a, MediaNode::Folder { .. });
        let b_is_folder = matches!(b, MediaNode::Folder { .. });
        if a_is_folder != b_is_folder {
            b_is_folder.cmp(&a_is_folder)
        } else {
            match (a, b) {
                (MediaNode::Folder { name: n1, .. }, MediaNode::Folder { name: n2, .. }) => {
                    n1.cmp(n2)
                }
                (MediaNode::File { name: n1, .. }, MediaNode::File { name: n2, .. }) => n1.cmp(n2),
                _ => std::cmp::Ordering::Equal,
            }
        }
    });

    Json(nodes).into_response()
}
