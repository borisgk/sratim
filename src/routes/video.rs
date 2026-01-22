use axum::{
    body::Body,
    extract::{Json, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio_util::io::ReaderStream;

use crate::metadata::{LocalMetadata, cleanup_filename, download_image, fetch_tmdb_metadata};
use crate::models::{
    AppState, FileEntry, ListParams, LookupParams, MetadataParams, StreamParams, SubtitleParams,
};
use crate::streaming::{
    ProcessStream, extract_subtitle, find_keyframe, probe_metadata, spawn_ffmpeg,
};

// ...

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
        return (StatusCode::NOT_FOUND, Json(Vec::<FileEntry>::new())).into_response();
    };

    let Ok(canonical_root) = state.movies_dir.canonicalize() else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };

    if !canonical_path.starts_with(&canonical_root) {
        return StatusCode::FORBIDDEN.into_response();
    }

    let mut entries = Vec::new();

    if let Ok(mut read_dir) = tokio::fs::read_dir(&canonical_path).await {
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

            if is_dir {
                entries.push(FileEntry {
                    name: file_name,
                    path: rel_path,
                    entry_type: "folder".to_string(),
                    title: None,
                    poster: None,
                });
            } else if is_file {
                if let Some(ext) = std::path::Path::new(&file_name)
                    .extension()
                    .and_then(|s| s.to_str())
                {
                    match ext.to_lowercase().as_str() {
                        "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv" => {
                            let mut title = None;
                            let mut poster = None;

                            // Check for Sidecar JSON
                            let json_path = canonical_path.join(format!("{}.json", file_name));
                            if json_path.exists() {
                                if let Ok(content) = tokio::fs::read_to_string(&json_path).await {
                                    if let Ok(meta) =
                                        serde_json::from_str::<LocalMetadata>(&content)
                                    {
                                        title = Some(meta.title);
                                        // Poster path is relative to movie? No, we might store it as absolute or relative.
                                        // Let's assume we store it as local file name like "movie.jpg"
                                        // But the frontend needs a way to access it.
                                        // The frontend will construct URL.
                                        // We just say "yes we have poster".
                                        if meta.poster_path.is_some() {
                                            // Check if image exists
                                            let img_path =
                                                canonical_path.join(format!("{}.jpg", file_name));
                                            if img_path.exists() {
                                                poster = Some(format!("{}.jpg", file_name));
                                            }
                                        }
                                    }
                                }
                            }

                            entries.push(FileEntry {
                                name: file_name,
                                path: rel_path,
                                entry_type: "file".to_string(),
                                title,
                                poster,
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
            if a.entry_type == "folder" {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            }
        }
    });

    Json(entries).into_response()
}

pub async fn get_metadata(
    State(state): State<AppState>,
    Query(params): Query<MetadataParams>,
) -> impl IntoResponse {
    let abs_path = state.movies_dir.join(&params.path);
    if !abs_path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    match probe_metadata(&abs_path).await {
        Ok(metadata) => Json(metadata).into_response(),
        Err(e) => {
            eprintln!("Metadata probe failed: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
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

    // Detect codec & audio & duration via unified probe
    let metadata = match probe_metadata(&abs_path).await {
        Ok(m) => m,
        Err(e) => {
            eprintln!("Probe failed: {}", e);
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };

    let codec_name = metadata.video_codec.clone();
    let duration = metadata.duration;
    let has_audio = !metadata.audio_tracks.is_empty();

    let mut actual_start = params.start;
    if actual_start > 0.0 {
        match find_keyframe(&abs_path, actual_start).await {
            Ok(k) => {
                actual_start = k;
            }
            Err(e) => {
                eprintln!("Keyframe probe failed: {}", e);
            }
        }
    }

    println!(
        "Detected for {}: Codec={}, AudioTracks={}, Duration={:.2}s, RequestedTrack={:?}, RequestedStart={:.2}, ActualStart={:.2}",
        params.path,
        codec_name,
        metadata.audio_tracks.len(),
        duration,
        params.audio_track,
        params.start,
        actual_start
    );

    // Resolve audio track index to pass to ffmpeg
    // If has_audio is true, we pass Some(requested_or_0). If false, None.
    let audio_track_idx = if has_audio {
        Some(params.audio_track.unwrap_or(0))
    } else {
        None
    };

    match spawn_ffmpeg(&abs_path, actual_start, audio_track_idx, &codec_name) {
        Ok(mut child) => {
            let stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();

            // Spawn stderr logger
            tokio::spawn(async move {
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
            let process_stream = ProcessStream::new(stream, child);

            Response::builder()
                .header("Content-Type", "video/mp4")
                .header("Cache-Control", "no-cache")
                .header("X-Video-Codec", codec_name)
                .header("X-Has-Audio", if has_audio { "true" } else { "false" })
                .header("X-Video-Duration", duration.to_string())
                .header("X-Actual-Start", actual_start.to_string())
                // No Content-Length, implies chunked if body is a stream
                .body(Body::from_stream(process_stream))
                .unwrap()
        }
        Err(e) => {
            eprintln!("Failed to spawn ffmpeg: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

// ...

pub async fn get_subtitles(
    State(state): State<AppState>,
    Query(params): Query<SubtitleParams>,
) -> impl IntoResponse {
    let abs_path = state.movies_dir.join(&params.path);
    if !abs_path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    match extract_subtitle(&abs_path, params.index) {
        Ok(mut child) => {
            let stdout = child.stdout.take().unwrap();
            let stderr = child.stderr.take().unwrap();

            // Spawn stderr logger
            tokio::spawn(async move {
                let mut reader = BufReader::new(stderr);
                let mut line = String::new();
                while let Ok(n) = reader.read_line(&mut line).await {
                    if n == 0 {
                        break;
                    }
                    eprint!("[ffmpeg-sub] {}", line);
                    line.clear();
                }
            });

            let stream = ReaderStream::new(stdout);
            let process_stream = ProcessStream::new(stream, child);

            Response::builder()
                .header("Content-Type", "text/vtt")
                .header("Cache-Control", "no-cache")
                .body(Body::from_stream(process_stream))
                .unwrap()
                .into_response()
        }
        Err(e) => {
            eprintln!("Failed to extract subtitles: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

pub async fn lookup_metadata(
    State(state): State<AppState>,
    Query(params): Query<LookupParams>,
) -> impl IntoResponse {
    let abs_path = state.movies_dir.join(&params.path);
    if !abs_path.exists() {
        return (StatusCode::NOT_FOUND, Json(None::<LocalMetadata>)).into_response();
    }

    let file_name = abs_path.file_name().unwrap().to_string_lossy().to_string();
    let (cleaned_name, year) = cleanup_filename(&file_name);

    println!(
        "Lookup metadata for: {} -> cleaned: '{}', year: {:?}",
        file_name, cleaned_name, year
    );

    let api_key = "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiI0YjY4NjgwZDI3MzVlYjdiMWVkNjIwZTQwZDNiMjYxMCIsIm5iZiI6MTY5MjE5NTc4Ny41MjQsInN1YiI6IjY0ZGNkYmNiMDAxYmJkMDQxYmY0NjhlOCIsInNjb3BlcyI6WyJhcGlfcmVhZCJdLCJ2ZXJzaW9uIjoxfQ.3kiXVao5QsftRTtLu2H5mfmO8K35tCtD0siaWdeCbTw";

    // 1. Search by filename with separated year
    let mut best_match = fetch_tmdb_metadata(&cleaned_name, year.as_deref(), api_key)
        .await
        .ok()
        .flatten();

    // 2. Fallback: Probe internal title
    if best_match.is_none() {
        println!("No match for filename, probing internal title...");
        if let Ok(meta) = probe_metadata(&abs_path).await {
            if let Some(internal_title) = meta.title {
                println!("Internal title found: {}", internal_title);
                // For internal title, we might not have a year explicitly separated,
                // or we could try to clean it too?
                // Let's clean the internal title as well to extract year if present.
                let (clean_int_title, int_year) = cleanup_filename(&internal_title);
                best_match = fetch_tmdb_metadata(&clean_int_title, int_year.as_deref(), api_key)
                    .await
                    .ok()
                    .flatten();
            }
        }
    }

    if let Some(m) = best_match {
        // Save to JSON
        // We want to match the logic in list_files, which looks for format!("{}.json", file_name)
        // file_name includes extension, e.g. "Movie.mkv". So we want "Movie.mkv.json"

        let json_path = abs_path
            .parent()
            .unwrap()
            .join(format!("{}.json", file_name));

        // Download poster if available
        if let Some(poster_suffix) = &m.poster_path {
            // Also matching list_files: format!("{}.jpg", file_name) -> "Movie.mkv.jpg"
            let img_path = abs_path
                .parent()
                .unwrap()
                .join(format!("{}.jpg", file_name));
            if let Err(e) = download_image(poster_suffix, &img_path).await {
                eprintln!("Failed to download image: {}", e);
            }
        }

        // We keep the original poster path in the struct (suffix) or full?
        // The definition has `poster_path: Option<String>`. TMDB returns suffix.
        // We should store suffix so we know we have it? Or store what we want to return?
        // Let's store what we got from TMDB.

        let content = serde_json::to_string_pretty(&m).unwrap();
        if let Err(e) = tokio::fs::write(&json_path, content).await {
            eprintln!("Failed to write metadata json: {}", e);
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }

        return Json(Some(m)).into_response();
    }

    // No match found
    (StatusCode::OK, Json(None::<LocalMetadata>)).into_response()
}
