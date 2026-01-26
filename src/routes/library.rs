use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use uuid::Uuid;

use crate::models::{AppState, Library, LibraryType};

const LIBRARIES_FILE: &str = "libraries.json";

#[derive(Deserialize)]
pub struct CreateLibraryPayload {
    pub name: String,
    pub path: String,
    pub kind: LibraryType,
}

#[derive(Serialize)]
pub struct FSEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
}

#[derive(Deserialize)]
pub struct BrowseParams {
    pub path: Option<String>,
}

pub async fn get_libraries(State(state): State<AppState>) -> impl IntoResponse {
    let libraries = state.libraries.read().await;
    Json(libraries.clone()).into_response()
}

pub async fn create_library(
    State(state): State<AppState>,
    Json(payload): Json<CreateLibraryPayload>,
) -> impl IntoResponse {
    let mut libraries = state.libraries.write().await;

    let id = Uuid::new_v4().to_string();
    let library = Library {
        id,
        name: payload.name,
        path: PathBuf::from(payload.path),
        kind: payload.kind,
    };

    libraries.push(library);

    // Persist
    if let Ok(content) = serde_json::to_string_pretty(&*libraries) {
        let _ = tokio::fs::write(LIBRARIES_FILE, content).await;
    }

    StatusCode::CREATED.into_response()
}

pub async fn delete_library(
    State(state): State<AppState>,
    Path(id): Path<String>,
) -> impl IntoResponse {
    let mut libraries = state.libraries.write().await;

    if let Some(pos) = libraries.iter().position(|l| l.id == id) {
        libraries.remove(pos);

        // Persist
        if let Ok(content) = serde_json::to_string_pretty(&*libraries) {
            let _ = tokio::fs::write(LIBRARIES_FILE, content).await;
        }

        return StatusCode::OK.into_response();
    }

    StatusCode::NOT_FOUND.into_response()
}

pub async fn browse_filesystem(Query(params): Query<BrowseParams>) -> impl IntoResponse {
    let path = if let Some(p) = params.path.filter(|s| !s.is_empty()) {
        PathBuf::from(p)
    } else {
        // Default to home dir or root
        #[allow(deprecated)]
        std::env::home_dir().unwrap_or(PathBuf::from("/"))
    };

    if !path.exists() || !path.is_dir() {
        eprintln!("Invalid path requested for browse: {:?}", path);
        return (StatusCode::BAD_REQUEST, "Invalid path").into_response();
    }

    let mut entries = Vec::new();

    if let Ok(mut read_dir) = tokio::fs::read_dir(&path).await {
        while let Ok(Some(entry)) = read_dir.next_entry().await {
            let file_name = entry.file_name().to_string_lossy().to_string();
            // Skip hidden files
            if file_name.starts_with('.') {
                continue;
            }

            let file_type = entry.file_type().await.ok();
            let is_dir = file_type.map(|t| t.is_dir()).unwrap_or(false);

            entries.push(FSEntry {
                name: file_name,
                path: entry.path().to_string_lossy().to_string(),
                is_dir,
            });
        }
    }

    // Sort folders first
    entries.sort_by(|a, b| {
        if a.is_dir == b.is_dir {
            a.name.to_lowercase().cmp(&b.name.to_lowercase())
        } else if a.is_dir {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Greater
        }
    });

    // Add parent directory option if not root
    if let Some(parent) = path.parent() {
        entries.insert(
            0,
            FSEntry {
                name: "..".to_string(),
                path: parent.to_string_lossy().to_string(),
                is_dir: true,
            },
        );
    }

    // Also include current path in response? Maybe easier for frontend to just track.

    Json(entries).into_response()
}

pub async fn serve_content(
    State(state): State<AppState>,
    Path((id, file_path)): Path<(String, String)>,
) -> impl IntoResponse {
    let libraries = state.libraries.read().await;

    if let Some(lib) = libraries.iter().find(|l| l.id == id) {
        let mut full_path = lib.path.clone();
        // Remove leading slash from file_path if present to avoid replacing root
        let clean_path = file_path.trim_start_matches('/');
        full_path.push(clean_path);

        // Security check: ensure we are taking about a file inside the library
        if full_path.exists() && full_path.starts_with(&lib.path) {
            // Simple mime guessing
            let mime = mime_guess::from_path(&full_path).first_or_octet_stream();

            if let Ok(file) = tokio::fs::File::open(full_path).await {
                let stream = tokio_util::io::ReaderStream::new(file);
                let body = axum::body::Body::from_stream(stream);

                return (
                    StatusCode::OK,
                    [(axum::http::header::CONTENT_TYPE, mime.as_ref())],
                    body,
                )
                    .into_response();
            }
        }
    }

    StatusCode::NOT_FOUND.into_response()
}
