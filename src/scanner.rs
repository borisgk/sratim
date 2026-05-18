use std::path::{Path, PathBuf};
use tokio::sync::mpsc;
use tokio::time::{Duration, sleep};

use crate::metadata::process_file;
use crate::models::{AppConfig, Library, LibraryType};

pub struct Scanner {
    tx: mpsc::Sender<ScanTask>,
    db: std::sync::Arc<crate::db::DbClient>,
}

#[derive(Debug)]
enum ScanTask {
    Movie(PathBuf),
    TVShow(PathBuf),
}

impl Scanner {
    pub fn new(
        config: AppConfig,
        db: std::sync::Arc<crate::db::DbClient>,
    ) -> (Self, tokio::task::JoinHandle<()>) {
        let (tx, mut rx) = mpsc::channel::<ScanTask>(100);
        let worker_config = config.clone();
        let worker_db = db.clone();

        let worker_handle = tokio::spawn(async move {
            println!("[scanner] Background worker started");
            while let Some(task) = rx.recv().await {
                // Rate limiting (Throttle)
                sleep(Duration::from_millis(500)).await;

                match task {
                    ScanTask::Movie(path) => {
                        println!("[scanner] Worker processing Movie: {:?}", path.file_name());
                        if let Err(e) = process_file(&path, &worker_config, false, &worker_db).await
                        {
                            eprintln!("[scanner] Error processing movie {:?}: {}", path, e);
                        }
                    }
                    ScanTask::TVShow(path) => {
                        println!("[scanner] Worker processing TV Show: {:?}", path.file_name());
                        if let Err(e) = process_file(&path, &worker_config, true, &worker_db).await
                        {
                            eprintln!("[scanner] Error processing TV show {:?}: {}", path, e);
                        }
                    }
                }
            }
            println!("[scanner] Background worker stopped");
        });

        (Self { tx, db }, worker_handle)
    }

    pub async fn scan_library(&self, library: &Library) {
        let tx = self.tx.clone();
        let db = self.db.clone();
        let lib_path = library.path.clone();
        let lib_kind = library.kind.clone();
        let lib_name = library.name.clone();

        println!("[scanner] Scanning library: {} ({:?})", lib_name, lib_path);

        tokio::spawn(async move {
            match lib_kind {
                LibraryType::Movies => {
                    Self::scan_movies(lib_path.clone(), db.clone(), tx).await;
                }
                LibraryType::TVShows => {
                    Self::scan_tv_shows(lib_path.clone(), db.clone(), tx).await;
                }
                _ => {
                    println!(
                        "[scanner] Skipping unsupported library type: {:?}",
                        lib_kind
                    );
                    return;
                }
            }

            println!("[scanner] Cleaning orphaned metadata for {}", lib_name);
            if let Err(e) = db
                .clean_orphaned_metadata(&lib_path.to_string_lossy())
                .await
            {
                eprintln!(
                    "[scanner] Error cleaning orphaned metadata for {}: {}",
                    lib_name, e
                );
            }
        });
    }

    async fn scan_movies(
        lib_path: PathBuf,
        db: std::sync::Arc<crate::db::DbClient>,
        tx: mpsc::Sender<ScanTask>,
    ) {
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
                            if !has_metadata(&path, &db).await {
                                // Prioritize adding new movies to the UI immediately with a placeholder
                                if super::metadata::read_local_metadata(&path, &db).await.is_none() {
                                    let raw_stem = path.file_stem().unwrap_or_default().to_string_lossy();
                                    let clean_title = super::metadata::cleanup_filename(&raw_stem);
                                    let placeholder = super::metadata::LocalMetadata {
                                        title: clean_title.0,
                                        overview: String::new(),
                                        poster_path: None,
                                        tmdb_id: 0,
                                        episode_number: None,
                                        added_at: None,
                                    };
                                    let _ = db.save_metadata(&path.to_string_lossy(), &placeholder).await;
                                }

                                println!(
                                    "[scanner] Queueing missing metadata (Movie): {:?}",
                                    path.file_name()
                                );
                                if let Err(e) = tx.send(ScanTask::Movie(path.clone())).await {
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

    async fn scan_tv_shows(
        lib_path: PathBuf,
        db: std::sync::Arc<crate::db::DbClient>,
        tx: mpsc::Sender<ScanTask>,
    ) {
        let mut dirs = vec![lib_path];
        while let Some(dir) = dirs.pop() {
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

                sleep(Duration::from_millis(1)).await;

                if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                    let lower_ext = ext.to_lowercase();
                    match lower_ext.as_str() {
                        "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv" => {
                            if !has_metadata(&path, &db).await {
                                println!("[scanner] Queueing missing metadata (TV Show): {:?}", path.file_name());
                                if let Err(e) = tx.send(ScanTask::TVShow(path)).await {
                                    eprintln!("[scanner] Failed to queue item: {}", e);
                                    break;
                                }
                                sleep(Duration::from_millis(10)).await;
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        println!("[scanner] Finished scanning TV Shows library");
    }
}

async fn has_metadata(video_path: &Path, db: &crate::db::DbClient) -> bool {
    let file_name = match video_path.file_name() {
        Some(n) => n.to_string_lossy(),
        None => return false,
    };

    let parent = video_path.parent();
    if parent.is_none() {
        return false;
    }
    let parent = parent.unwrap();

    let jpg_path = parent.join(format!("{}.jpg", file_name));

    if super::metadata::read_local_metadata(video_path, db)
        .await
        .is_some()
    {
        return jpg_path.exists();
    }
    false
}
