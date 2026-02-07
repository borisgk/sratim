use regex::Regex;
use std::path::{Path, PathBuf};
use tokio::sync::mpsc;
use tokio::time::{Duration, sleep};

use crate::metadata::{
    download_image, fetch_tmdb_episode_metadata, fetch_tmdb_season_metadata, process_file,
    read_local_metadata, save_local_metadata,
};
use crate::models::{AppConfig, Library, LibraryType};

pub struct Scanner {
    tx: mpsc::Sender<ScanTask>,
    config: AppConfig,
}

#[derive(Debug)]
enum ScanTask {
    Movie(PathBuf),
    Season {
        path: PathBuf,
        tmdb_id: u64,
        season_num: u32,
    },
    Episode {
        path: PathBuf,
        tmdb_id: u64,
        season_num: u32,
        episode_num: u32,
    },
}

impl Scanner {
    pub fn new(config: AppConfig) -> (Self, tokio::task::JoinHandle<()>) {
        let (tx, mut rx) = mpsc::channel::<ScanTask>(100);
        let worker_config = config.clone();

        let worker_handle = tokio::spawn(async move {
            println!("[scanner] Background worker started");
            while let Some(task) = rx.recv().await {
                // Rate limiting (Throttle)
                sleep(Duration::from_millis(500)).await;

                match task {
                    ScanTask::Movie(path) => {
                        println!("[scanner] Worker processing Movie: {:?}", path.file_name());
                        if let Err(e) = process_file(&path, &worker_config, false).await {
                            eprintln!("[scanner] Error processing movie {:?}: {}", path, e);
                        }
                    }
                    ScanTask::Season {
                        path,
                        tmdb_id,
                        season_num,
                    } => {
                        println!(
                            "[scanner] Worker processing Season: S{:02} (Show={})",
                            season_num, tmdb_id
                        );
                        match fetch_tmdb_season_metadata(&worker_config, tmdb_id, season_num).await
                        {
                            Ok(Some(meta)) => {
                                if let Err(e) = save_local_metadata(&path, &meta).await {
                                    eprintln!("[scanner] Failed to save season metadata: {}", e);
                                } else {
                                    if let Some(poster) = meta.poster_path {
                                        let img_path = path.parent().unwrap().join(format!(
                                            "{}.jpg",
                                            path.file_name().unwrap().to_string_lossy()
                                        ));
                                        let _ = download_image(&worker_config, &poster, &img_path)
                                            .await;
                                    }
                                }
                            }
                            Ok(None) => {
                                println!("[scanner] No metadata found for Season {}", season_num)
                            }
                            Err(e) => eprintln!("[scanner] Error fetching season metadata: {}", e),
                        }
                    }
                    ScanTask::Episode {
                        path,
                        tmdb_id,
                        season_num,
                        episode_num,
                    } => {
                        println!(
                            "[scanner] Worker processing Episode: S{:02}E{:02} (Show={})",
                            season_num, episode_num, tmdb_id
                        );
                        match fetch_tmdb_episode_metadata(
                            &worker_config,
                            tmdb_id,
                            season_num,
                            episode_num,
                        )
                        .await
                        {
                            Ok(Some(meta)) => {
                                if let Err(e) = save_local_metadata(&path, &meta).await {
                                    eprintln!("[scanner] Failed to save episode metadata: {}", e);
                                } else {
                                    if let Some(poster) = meta.poster_path {
                                        // For episodes, image usually goes next to file too? Or no image?
                                        // Let's download valid internal metadata. title="", poster=""
                                        let img_path = path.parent().unwrap().join(format!(
                                            "{}.jpg",
                                            path.file_name().unwrap().to_string_lossy()
                                        ));
                                        let _ = download_image(&worker_config, &poster, &img_path)
                                            .await;
                                    }
                                }
                            }
                            Ok(None) => println!(
                                "[scanner] No metadata found for Episode S{:02}E{:02}",
                                season_num, episode_num
                            ),
                            Err(e) => eprintln!("[scanner] Error fetching episode metadata: {}", e),
                        }
                    }
                }
            }
            println!("[scanner] Background worker stopped");
        });

        (Self { tx, config }, worker_handle)
    }

    pub async fn scan_library(&self, library: &Library) {
        let tx = self.tx.clone();
        let config = self.config.clone(); // Clone config for the task
        let lib_path = library.path.clone();
        let lib_kind = library.kind.clone();
        let lib_name = library.name.clone();

        println!("[scanner] Scanning library: {} ({:?})", lib_name, lib_path);

        tokio::spawn(async move {
            match lib_kind {
                LibraryType::Movies => {
                    Self::scan_movies(lib_path, tx).await;
                }
                LibraryType::TVShows => {
                    Self::scan_tv_shows(config, lib_path, tx).await;
                }
                _ => {
                    println!(
                        "[scanner] Skipping unsupported library type: {:?}",
                        lib_kind
                    );
                }
            }
        });
    }

    async fn scan_movies(lib_path: PathBuf, tx: mpsc::Sender<ScanTask>) {
        let mut dirs = vec![lib_path];
        while let Some(dir) = dirs.pop() {
            // Yield to allow other tasks (like HTTP requests) to run
            tokio::task::yield_now().await;

            let mut entries = match tokio::fs::read_dir(&dir).await {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("[scanner] Failed to read dir {:?}: {}", dir, e);
                    continue;
                }
            };

            while let Ok(Some(entry)) = entries.next_entry().await {
                let path = entry.path();
                if path.is_dir() {
                    dirs.push(path);
                    continue;
                }

                // Throttle: sleep 1ms per file check to act as "low priority" background task
                sleep(Duration::from_millis(1)).await;

                if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                    let lower_ext = ext.to_lowercase();
                    match lower_ext.as_str() {
                        "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv" => {
                            if !has_metadata(&path) {
                                println!(
                                    "[scanner] Queueing missing metadata (Movie): {:?}",
                                    path.file_name()
                                );
                                if let Err(e) = tx.send(ScanTask::Movie(path)).await {
                                    eprintln!("[scanner] Failed to queue item: {}", e);
                                    break;
                                }
                                // Small sleep after queuing to prevent channel saturation bursts
                                sleep(Duration::from_millis(10)).await;
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        println!("[scanner] Finished scanning Movies library");
    }

    async fn scan_tv_shows(config: AppConfig, lib_path: PathBuf, tx: mpsc::Sender<ScanTask>) {
        let mut entries = match tokio::fs::read_dir(&lib_path).await {
            Ok(e) => e,
            Err(e) => {
                eprintln!("[scanner] Failed to read TV dir {:?}: {}", lib_path, e);
                return;
            }
        };

        // Recursive scan but starting with Top-Level assumptions
        while let Ok(Some(entry)) = entries.next_entry().await {
            // Yield per entry to be polite
            tokio::task::yield_now().await;

            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            // This is a SHOW folder (Top Level)
            // 1. Check if Show metadata exists
            let tmdb_id;

            if let Some(meta) = read_local_metadata(&path).await {
                // Metadata exists, use it
                tmdb_id = Some(meta.tmdb_id);
            } else {
                println!(
                    "[scanner] New TV Show detected: {:?}. Processing inline to enable deep scan...",
                    path.file_name()
                );
                // Process inline to get ID immediately
                // We default is_tv=true
                match process_file(&path, &config, true).await {
                    Ok(Some(meta)) => {
                        tmdb_id = Some(meta.tmdb_id);
                        println!(
                            "[scanner] Inline processing successful. ID: {}",
                            meta.tmdb_id
                        );
                    }
                    Ok(None) => {
                        println!("[scanner] Inline processing failed to find match.");
                        tmdb_id = None;
                    }
                    Err(e) => {
                        eprintln!("[scanner] Inline processing error: {}", e);
                        tmdb_id = None;
                    }
                }
                // Sleep to throttle network usage since we just did a request
                sleep(Duration::from_millis(500)).await;
            }

            let show_id = match tmdb_id {
                Some(id) => id,
                None => continue,
            };

            // 2. Scan Children (Seasons/Episodes)
            Self::scan_show_children(&path, show_id, tx.clone()).await;
        }
        println!("[scanner] Finished scanning TV Shows library");
    }

    async fn scan_show_children(show_path: &Path, show_id: u64, tx: mpsc::Sender<ScanTask>) {
        println!(
            "[scanner] Entering scan_show_children for {:?} (ID: {})",
            show_path, show_id
        );
        let mut dirs = vec![show_path.to_path_buf()];

        while let Some(dir) = dirs.pop() {
            println!("[scanner] Scanning directory: {:?}", dir);
            tokio::task::yield_now().await;

            let mut entries = match tokio::fs::read_dir(&dir).await {
                Ok(e) => e,
                Err(e) => {
                    eprintln!("[scanner] Failed to read dir {:?}: {}", dir, e);
                    continue;
                }
            };

            while let Ok(Some(entry)) = entries.next_entry().await {
                let path = entry.path();
                // Throttle
                sleep(Duration::from_millis(1)).await;

                if path.is_dir() {
                    // Check if Season folder
                    let file_name = path.file_name().unwrap().to_string_lossy();
                    let season_re = Regex::new(r"(?i)season\s*(\d+)|s(\d+)").unwrap();
                    if let Some(caps) = season_re.captures(&file_name) {
                        let s_num = caps
                            .get(1)
                            .or(caps.get(2))
                            .unwrap()
                            .as_str()
                            .parse::<u32>()
                            .unwrap();
                        println!(
                            "[scanner] Found Season folder: {:?} (Season {})",
                            file_name, s_num
                        );

                        // Check metadata for Season Folder
                        if !has_metadata(&path) {
                            println!(
                                "[scanner] Queueing missing metadata (Season {}): {:?}",
                                s_num,
                                path.file_name()
                            );
                            let _ = tx
                                .send(ScanTask::Season {
                                    path: path.clone(),
                                    tmdb_id: show_id,
                                    season_num: s_num,
                                })
                                .await;
                            sleep(Duration::from_millis(10)).await;
                        }
                    }
                    // Recurse
                    dirs.push(path);
                    continue;
                }

                // File: Check if Episode
                if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                    match ext.to_lowercase().as_str() {
                        "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv" => {
                            if !has_metadata(&path) {
                                // Try parse SxxExx
                                let file_name = path.file_name().unwrap().to_string_lossy();
                                // Loose regex to catch S01E01 or 1x01
                                let ep_re = Regex::new(r"(?i)[sS](\d{1,2})[eE](\d{1,2})").unwrap();

                                if let Some(caps) = ep_re.captures(&file_name) {
                                    let s_num = caps[1].parse::<u32>().unwrap();
                                    let e_num = caps[2].parse::<u32>().unwrap();
                                    println!(
                                        "[scanner] Found Episode file: {:?} (S{}E{})",
                                        file_name, s_num, e_num
                                    );

                                    println!(
                                        "[scanner] Queueing missing metadata (Episode S{:02}E{:02}): {:?}",
                                        s_num,
                                        e_num,
                                        path.file_name()
                                    );
                                    let _ = tx
                                        .send(ScanTask::Episode {
                                            path: path.clone(),
                                            tmdb_id: show_id,
                                            season_num: s_num,
                                            episode_num: e_num,
                                        })
                                        .await;
                                    sleep(Duration::from_millis(10)).await;
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
    }
}

fn has_metadata(video_path: &Path) -> bool {
    let file_name = match video_path.file_name() {
        Some(n) => n.to_string_lossy(),
        None => return false,
    };

    let parent = video_path.parent();
    if parent.is_none() {
        return false;
    }
    let parent = parent.unwrap();

    let json_path = parent.join(format!("{}.json", file_name));
    let jpg_path = parent.join(format!("{}.jpg", file_name));

    // For now, require JSON. Image optional for existence check?
    // Logic said "missing metadata (json AND jpg)".
    // `read_local_metadata` needs JSON.
    // Let's stick to existing logic:
    json_path.exists() && jpg_path.exists()
}
