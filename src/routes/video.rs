use axum::{
    body::Body,
    extract::{Json, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
};
use regex::Regex;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio_util::io::ReaderStream;

use crate::metadata::{
    LocalMetadata, cleanup_filename, download_image, fetch_tmdb_metadata,
    fetch_tmdb_season_metadata, fetch_tmdb_episode_metadata,
    read_local_metadata, save_local_metadata,
};
use crate::models::{
    AppState, FileEntry, ListParams, LookupParams, MetadataParams, StreamParams, SubtitleParams,
};
use crate::streaming::{
    ProcessStream, extract_subtitle, find_keyframe, probe_metadata, spawn_ffmpeg,
};

// ...

pub async fn get_base_path(
    state: &AppState,
    library_id: Option<&str>,
) -> Option<std::path::PathBuf> {
    if let Some(id) = library_id {
        let libraries = state.libraries.read().await;
        if let Some(lib) = libraries.iter().find(|l| l.id == id) {
            return Some(lib.path.clone());
        }
    }
    None
}

pub async fn list_files(
    State(state): State<AppState>,
    Query(params): Query<ListParams>,
) -> impl IntoResponse {
    if params.library_id.is_none() && params.path.is_empty() {
        // "Add Library" initial state: Return empty list for root
        return Json(Vec::<FileEntry>::new()).into_response();
    }

    let Some(base_path) = get_base_path(&state, params.library_id.as_deref()).await else {
        return (StatusCode::BAD_REQUEST, "Library not found").into_response();
    };

    let mut abs_path = base_path.clone();
    abs_path.push(&params.path);

    // Security check: ensure we didn't escape movies_dir
    let Ok(canonical_path) = abs_path.canonicalize() else {
        return (StatusCode::NOT_FOUND, Json(Vec::<FileEntry>::new())).into_response();
    };

    let Ok(canonical_root) = base_path.canonicalize() else {
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
                let mut title = None;
                let mut poster = None;

                let item_path = canonical_path.join(&file_name);
                if let Some(meta) = read_local_metadata(&item_path, &state.db).await {
                    title = Some(meta.title);
                    if meta.poster_path.is_some() {
                        let img_path = canonical_path.join(format!("{}.jpg", file_name));
                        if img_path.exists() {
                            poster = Some(format!("{}.jpg", file_name));
                        }
                    }
                }

                entries.push(FileEntry {
                    name: file_name,
                    path: rel_path,
                    entry_type: "folder".to_string(),
                    title,
                    poster,
                });
            } else if is_file
                && let Some(ext) = std::path::Path::new(&file_name)
                    .extension()
                    .and_then(|s| s.to_str())
            {
                match ext.to_lowercase().as_str() {
                    "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv" => {
                        let mut title = None;
                        let mut poster = None;

                        // Check for Sidecar JSON
                        let item_path = canonical_path.join(&file_name);
                        if let Some(meta) = read_local_metadata(&item_path, &state.db).await {
                            if !meta.title.is_empty() {
                                if let Some(ep_num) = meta.episode_number {
                                    title = Some(format!("{}. {}", ep_num, meta.title));
                                } else {
                                    title = Some(meta.title);
                                }
                            }
                            // Check if image exists
                            let img_path = canonical_path.join(format!("{}.jpg", file_name));
                            if img_path.exists() {
                                poster = Some(format!("{}.jpg", file_name));
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

    // Sort: Folders first, then files. Both alphabetical.
    entries.sort_by(|a, b| {
        if a.entry_type == b.entry_type {
            a.name.to_lowercase().cmp(&b.name.to_lowercase())
        } else if a.entry_type == "folder" {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Greater
        }
    });

    Json(entries).into_response()
}

pub async fn get_metadata(
    State(state): State<AppState>,
    Query(params): Query<MetadataParams>,
) -> impl IntoResponse {
    let Some(base_path) = get_base_path(&state, params.library_id.as_deref()).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let abs_path = base_path.join(&params.path);
    if !abs_path.exists() {
        return StatusCode::NOT_FOUND.into_response();
    }

    match probe_metadata(&abs_path).await {
        Ok(mut metadata) => {
            // Check for sidecar JSON
            if let Some(meta) = read_local_metadata(&abs_path, &state.db).await
                && !meta.title.is_empty()
            {
                metadata.title = Some(meta.title);
            }
            Json(metadata).into_response()
        }
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
    let Some(base_path) = get_base_path(&state, params.library_id.as_deref()).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let abs_path = base_path.join(&params.path);
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

pub async fn get_subtitles(
    State(state): State<AppState>,
    Query(params): Query<SubtitleParams>,
) -> impl IntoResponse {
    let Some(base_path) = get_base_path(&state, params.library_id.as_deref()).await else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let abs_path = base_path.join(&params.path);
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
    axum::Extension(claims): axum::Extension<crate::auth::Claims>,
    Query(params): Query<LookupParams>,
) -> impl IntoResponse {
    let decoded_path = urlencoding::decode(&params.path)
        .unwrap_or(std::borrow::Cow::Borrowed(&params.path))
        .to_string();
    println!(
        "[lookup_metadata] Called with library_id={:?}, path='{}' (decoded='{}')",
        params.library_id, params.path, decoded_path
    );

    if !claims.is_admin {
        return (StatusCode::FORBIDDEN, "Admin access required").into_response();
    }
    
    let libraries = state.libraries.read().await;
    let lib = libraries.iter().find(|l| Some(l.id.as_str()) == params.library_id.as_deref());
    let (base_path, is_tv) = match lib {
        Some(l) => (l.path.clone(), l.kind == crate::models::LibraryType::TVShows),
        None => return (StatusCode::NOT_FOUND, Json(None::<LocalMetadata>)).into_response(),
    };
    drop(libraries);
    let abs_path = base_path.join(&decoded_path);
    if !abs_path.exists() {
        println!("[lookup_metadata] File path does not exist: {:?}", abs_path);
        return (StatusCode::NOT_FOUND, Json(None::<LocalMetadata>)).into_response();
    }

    let is_dir = abs_path.is_dir();
    let file_name = abs_path.file_name().unwrap().to_string_lossy().to_string();
    let (cleaned_name, year) = cleanup_filename(&file_name);

    println!(
        "Lookup metadata for: {} (is_dir: {}) -> cleaned: '{}', year: {:?}",
        file_name, is_dir, cleaned_name, year
    );

    let mut best_match = None;

    if is_tv {
        let ep_re = Regex::new(r"(?i)s(\d{1,2})e(\d{1,2})").unwrap();
        let season_re = Regex::new(r"(?i)season\s*(\d+)").unwrap();
        let alt_ep_re = Regex::new(r"[\._\s-]([0-9]{2,3})[\._\s-]").unwrap();

        if !is_dir {
            let mut matched_season = None;
            let mut matched_episode = None;
            let mut show_name_from_file = None;

            if let Some(caps) = ep_re.captures(&file_name) {
                matched_season = Some(caps[1].parse().unwrap());
                matched_episode = Some(caps[2].parse().unwrap());
                show_name_from_file = Some(file_name[..caps.get(0).unwrap().start()].to_string());
            } else if let Some(caps) = alt_ep_re.captures(&file_name) {
                matched_season = Some(1); // Default to season 1 for simple episode numbering
                matched_episode = Some(caps[1].parse().unwrap());
                show_name_from_file = Some(file_name[..caps.get(0).unwrap().start()].to_string());
            }

            if let (Some(season), Some(episode), Some(file_show)) = (matched_season, matched_episode, show_name_from_file) {
                let parent_dir_name = abs_path.parent().unwrap().file_name().unwrap().to_string_lossy();
                let parent_path = abs_path.parent().unwrap();
                
                let show_name = if parent_path == base_path.as_path() {
                    file_show
                } else if season_re.is_match(&parent_dir_name) {
                    parent_path.parent().unwrap().file_name().unwrap().to_string_lossy().to_string()
                } else {
                    parent_dir_name.to_string()
                };
                
                let (clean_show, show_year) = cleanup_filename(&show_name);

                if let Ok(Some(show_meta)) = fetch_tmdb_metadata(&state.config, &clean_show, show_year.as_deref(), true).await {
                    if let Ok(Some(ep_meta)) = fetch_tmdb_episode_metadata(&state.config, show_meta.tmdb_id, season, episode).await {
                        best_match = Some(ep_meta);
                    }
                }
            }
        } else {
            if let Some(caps) = season_re.captures(&file_name) {
                let season: u32 = caps[1].parse().unwrap();
                let parent_dir_name = abs_path.parent().unwrap().file_name().unwrap().to_string_lossy();
                let (clean_show, show_year) = cleanup_filename(&parent_dir_name);
                
                if let Ok(Some(show_meta)) = fetch_tmdb_metadata(&state.config, &clean_show, show_year.as_deref(), true).await {
                    if let Ok(Some(season_meta)) = fetch_tmdb_season_metadata(&state.config, show_meta.tmdb_id, season).await {
                        best_match = Some(season_meta);
                    }
                }
            }
        }
    }

    if best_match.is_none() {
        println!(
            "Falling back to filename search. Cleaned='{}', Year={:?}",
            cleaned_name, year
        );
        // 1. Search by filename with separated year
        match fetch_tmdb_metadata(&state.config, &cleaned_name, year.as_deref(), is_tv)
            .await
        {
            Ok(res) => {
                best_match = res;
                if best_match.is_some() {
                    println!("Filename search successful.");
                } else {
                    println!("Filename search returned no results.");
                }
            }
            Err(e) => {
                println!("Filename search failed with error: {}", e);
            }
        }
    }

    // 2. Fallback: Probe internal title (only for files)
    if best_match.is_none() && !is_dir {
        println!("No match for filename, probing internal title...");
        if let Ok(meta) = probe_metadata(&abs_path).await {
            if let Some(internal_title) = meta.title {
                println!("Internal title found: {}", internal_title);
                let (clean_int_title, int_year) = cleanup_filename(&internal_title);
                best_match = fetch_tmdb_metadata(
                    &state.config,
                    &clean_int_title,
                    int_year.as_deref(),
                    is_tv
                )
                .await
                .ok()
                .flatten();
            } else {
                println!("No internal title found.");
            }
        } else {
            println!("Probe failed.");
        }
    }

    if let Some(m) = best_match {
        println!("Match found! Saving metadata...");
        // Save to JSON
        // We want to match the logic in list_files, which looks for format!("{}.json", file_name)
        // file_name includes extension, e.g. "Movie.mkv". So we want "Movie.mkv.json"

        // Download poster if available
        if let Some(poster_suffix) = &m.poster_path {
            // Also matching list_files: format!("{}.jpg", file_name) -> "Movie.mkv.jpg"
            let img_path = abs_path
                .parent()
                .unwrap()
                .join(format!("{}.jpg", file_name));
            if let Err(e) = download_image(&state.config, poster_suffix, &img_path).await {
                eprintln!("Failed to download image: {}", e);
            }
        }

        if let Err(e) = save_local_metadata(&abs_path, &m, &state.db).await {
            eprintln!("Failed to write metadata json: {}", e);
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }

        return Json(Some(m)).into_response();
    }

    println!("Lookup finished with no match.");
    // No match found
    (StatusCode::OK, Json(None::<LocalMetadata>)).into_response()
}
