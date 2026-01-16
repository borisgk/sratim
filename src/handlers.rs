use crate::models::{ListParams, MediaNode, StopParams, SubtitleParams, TranscodeParams};
use crate::state::AppState;
use axum::{
    body::Body,
    extract::{Json, Query, State},
    http::{Response, StatusCode},
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
) -> Result<Response<Body>, StatusCode> {
    let path = state.movies_dir.join(&params.path);

    if !path.exists() {
        return Err(StatusCode::NOT_FOUND);
    }

    // Use our custom transcoder
    let transcoder = crate::transcode::Transcoder::new(path.clone());
    let start_pos = params.start;
    let audio_stream_index = params.audio_track;

    let stream = transcoder
        .stream(start_pos, audio_stream_index)
        .await
        .map_err(|e| {
            tracing::error!("Transcode failed: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let session_id = stream.session_id().to_string();
    tracing::info!(
        "Transcode started for file {:?}. Session ID: {}",
        path,
        session_id
    );

    let body = Body::from_stream(stream);

    Ok(Response::builder()
        .header("Content-Type", "video/mp4")
        .header("X-Sratim-Session-Id", session_id)
        .header("Accept-Ranges", "none")
        .body(body)
        .unwrap())
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
        println!("[stop] Searching for processes matching file: {}", filename);

        // Find pids using pgrep
        let pgrep_output = Command::new("pgrep")
            .arg("-a") // Show full command line
            .arg("-f") // Match against full command line
            .arg("ffmpeg")
            .output();

        match pgrep_output {
            Ok(output) if output.status.success() => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                for line in stdout.lines() {
                    if line.contains(filename) {
                        // Line format: "PID COMMAND..."
                        if let Some(pid_str) = line.split_whitespace().next() {
                            println!("[stop] Found matching process: {}", line);
                            if let Ok(pid) = pid_str.parse::<i32>() {
                                unsafe {
                                    libc::kill(pid, libc::SIGKILL);
                                    println!("[stop] Sent SIGKILL to {}", pid);
                                }
                            }
                        }
                    }
                }
            }
            Ok(_) => println!("[stop] No ffmpeg processes found by pgrep."),
            Err(e) => eprintln!("[stop] Failed to run pgrep: {}", e),
        }
    }

    StatusCode::OK
}
