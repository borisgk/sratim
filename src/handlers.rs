use crate::models::{ListParams, MediaNode, StopParams, SubtitleParams, TranscodeParams};
use crate::state::AppState;
use axum::{
    extract::{Json, Query, State},
    http::StatusCode,
    response::{IntoResponse, Json as JsonResponse},
};
use std::process::Command;
use std::sync::Arc;

pub async fn list_movies(
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

    JsonResponse(nodes).into_response()
}

pub async fn get_metadata(
    State(state): State<Arc<AppState>>,
    Query(params): Query<TranscodeParams>,
) -> impl IntoResponse {
    let path = state.movies_dir.join(&params.path);

    if !path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    let transcoder = crate::transcode::Transcoder::new(path);
    match transcoder.get_metadata().await {
        Ok(info) => JsonResponse(info).into_response(),
        Err(e) => {
            eprintln!("Metadata failed: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

pub async fn transcode_movie(
    State(state): State<Arc<AppState>>,
    Query(params): Query<TranscodeParams>,
) -> impl IntoResponse {
    let path = state.movies_dir.join(&params.path);

    if !path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    // Use our custom transcoder
    let transcoder = crate::transcode::Transcoder::new(path.clone());

    match transcoder.stream(params.start, params.audio_track).await {
        Ok(stream) => axum::response::Response::builder()
            .header("Content-Type", "video/mp4")
            .header("Accept-Ranges", "none")
            .body(axum::body::Body::from_stream(stream))
            .unwrap(),
        Err(e) => {
            eprintln!("Failed to start transcoder: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

pub async fn extract_subtitles(
    State(state): State<Arc<AppState>>,
    Query(params): Query<SubtitleParams>,
) -> impl IntoResponse {
    let path = state.movies_dir.join(&params.path);

    if !path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    let transcoder = crate::transcode::Transcoder::new(path.clone());

    match transcoder.subtitles(params.index).await {
        Ok(stream) => axum::response::Response::builder()
            .header("Content-Type", "text/vtt")
            .header("Accept-Ranges", "none")
            .body(axum::body::Body::from_stream(stream))
            .unwrap(),
        Err(e) => {
            eprintln!("Failed to extract subtitles: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[allow(dead_code)]
pub async fn stop_transcode(
    State(state): State<Arc<AppState>>,
    Json(params): Json<StopParams>,
) -> impl IntoResponse {
    let path = state.movies_dir.join(&params.path);
    // We no longer have a manager to stop tasks via ID.
    // However, we still execute the brute-force pkill to ensure
    // any process working on this file is terminated.
    // This is the "Safety Net" requested by the user.

    // Brute-force verification: pkill any ffmpeg handling this file
    if let Some(filename) = path.file_name().and_then(|f| f.to_str()) {
        println!("[stop] Executing pkill fallback for file: {}", filename);
        let output = Command::new("pkill")
            .arg("-f")
            // We adding a -e and -x flag for more verbose pkill output if available, but -f is standard.
            // Let's print the status.
            .arg(format!("ffmpeg.*{}", filename))
            .output();

        match output {
            Ok(o) => println!(
                "[stop] pkill finished with status: {:?}, stdout: {:?}, stderr: {:?}",
                o.status,
                String::from_utf8_lossy(&o.stdout),
                String::from_utf8_lossy(&o.stderr)
            ),
            Err(e) => eprintln!("[stop] pkill failed to execute: {}", e),
        }
    }

    StatusCode::OK
}
