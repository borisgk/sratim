use axum::{
    Router,
    extract::{Query, State},
    response::{IntoResponse, Json},
    routing::get,
};
use serde::{Deserialize, Serialize};
use std::{net::SocketAddr, path::PathBuf, sync::Arc};
use tower_http::{cors::CorsLayer, services::ServeDir};
use walkdir::WalkDir;

mod transcode;

#[derive(Clone)]
struct AppState {
    movies_dir: PathBuf,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum MediaNode {
    Folder {
        name: String,
        children: Vec<MediaNode>,
    },
    File {
        name: String,
        path: String,
    },
}

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::fmt::init();

    // Configuration - You can change this path to where your movies are
    let movies_dir = PathBuf::from("movies");
    if !movies_dir.exists() {
        std::fs::create_dir_all(&movies_dir).expect("Failed to create movies directory");
        println!("Created 'movies' directory. Put your MKV files there!");
    }

    let shared_state = Arc::new(AppState {
        movies_dir: movies_dir.clone(),
    });

    // Router
    let app = Router::new()
        .route("/api/movies", get(list_movies))
        // Serve the movies directory directly so browsers can request ranges
        .nest_service("/content", ServeDir::new(&movies_dir))
        .route("/api/transcode", get(transcode_movie))
        .route("/api/metadata", get(get_metadata))
        .route("/api/subtitles", get(extract_subtitles))
        // Serve the frontend
        .fallback_service(ServeDir::new("frontend"))
        .layer(CorsLayer::permissive())
        .with_state(shared_state);

    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    println!("Server running on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

#[derive(Deserialize)]
struct TranscodeParams {
    path: String,
    start: Option<f64>,
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
    match transcoder.get_metadata() {
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
    let transcoder = crate::transcode::Transcoder::new(path);

    match transcoder.stream(params.start) {
        Ok(rx) => {
            // Create a stream from the receiver
            let stream = async_stream::stream! {
                // In a real implementation we would iterate the receiver
                // For now, we just yield what we get
                loop {
                    // This is blocking, so we should spawn it or use async channel
                    // For the POC, we'll assume the channel has data or breaks
                    match rx.recv() {
                        Ok(bytes) => yield Ok::<_, std::io::Error>(axum::body::Bytes::from(bytes)),
                        Err(_) => break, // Channel closed
                    }
                }
            };

            axum::response::Response::builder()
                .header("Content-Type", "video/mp4")
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

    let transcoder = crate::transcode::Transcoder::new(path);

    match transcoder.subtitles(params.index) {
        Ok(rx) => {
            let stream = async_stream::stream! {
                loop {
                    match rx.recv() {
                        Ok(bytes) => yield Ok::<_, std::io::Error>(axum::body::Bytes::from(bytes)),
                        Err(_) => break,
                    }
                }
            };

            axum::response::Response::builder()
                .header("Content-Type", "text/vtt")
                .body(axum::body::Body::from_stream(stream))
                .unwrap()
        }
        Err(e) => {
            eprintln!("Failed to extract subtitles: {}", e);
            axum::http::StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn list_movies(State(state): State<Arc<AppState>>) -> Json<Vec<MediaNode>> {
    use std::collections::BTreeMap;

    // We'll use a nested BTreeMap to build the hierarchy easily
    // String -> Folder/File
    enum TempNode {
        Dir(BTreeMap<String, TempNode>),
        Movie(String), // path
    }

    let mut root_map = BTreeMap::new();

    // Walk the directory and find video files
    for entry in WalkDir::new(&state.movies_dir)
        .into_iter()
        .filter_map(|e| e.ok())
    {
        let path = entry.path();
        if path.is_file() {
            if let Some(ext) = path.extension() {
                let ext_str = ext.to_string_lossy().to_lowercase();
                if ["mkv", "mp4", "webm", "avi", "mov"].contains(&ext_str.as_str()) {
                    let relative_path = path.strip_prefix(&state.movies_dir).unwrap_or(path);
                    let url_path = relative_path.to_string_lossy().replace('\\', "/");

                    // Navigate/Create the map structure for this path
                    let mut current_map = &mut root_map;
                    let components: Vec<_> = relative_path.components().collect();

                    for (i, component) in components.iter().enumerate() {
                        let name = component.as_os_str().to_string_lossy().to_string();

                        if i == components.len() - 1 {
                            // It's the file
                            current_map.insert(name, TempNode::Movie(url_path.clone()));
                        } else {
                            // It's a directory
                            current_map = match current_map
                                .entry(name)
                                .or_insert_with(|| TempNode::Dir(BTreeMap::new()))
                            {
                                TempNode::Dir(m) => m,
                                _ => unreachable!(),
                            };
                        }
                    }
                }
            }
        }
    }

    // Recursively convert TempNode tree to MediaNode tree
    fn convert(name: String, node: TempNode) -> MediaNode {
        match node {
            TempNode::Movie(path) => MediaNode::File { name, path },
            TempNode::Dir(map) => {
                let mut children = Vec::new();
                for (name, node) in map {
                    children.push(convert(name, node));
                }
                MediaNode::Folder { name, children }
            }
        }
    }

    let mut result = Vec::new();
    for (name, node) in root_map {
        result.push(convert(name, node));
    }

    Json(result)
}
