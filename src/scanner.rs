use std::path::{Path, PathBuf};
use tokio::sync::mpsc;
use tokio::time::{Duration, sleep};

use crate::metadata::process_file;
use crate::models::{AppConfig, Library, LibraryType};

pub struct Scanner {
    tx: mpsc::Sender<ScanTask>,
}

struct ScanTask {
    path: PathBuf,
    is_tv: bool,
}

impl Scanner {
    pub fn new(config: AppConfig) -> (Self, tokio::task::JoinHandle<()>) {
        let (tx, mut rx) = mpsc::channel::<ScanTask>(100);

        let worker_handle = tokio::spawn(async move {
            println!("[scanner] Background worker started");
            while let Some(task) = rx.recv().await {
                println!(
                    "[scanner] Worker picked up: {:?} (is_tv: {})",
                    task.path, task.is_tv
                );

                // Rate limiting to be polite to TMDB
                sleep(Duration::from_millis(500)).await;

                // Process
                if let Err(e) = process_file(&task.path, &config, task.is_tv).await {
                    eprintln!("[scanner] Error processing {:?}: {}", task.path, e);
                }
            }
            println!("[scanner] Background worker stopped");
        });

        (Self { tx }, worker_handle)
    }

    pub async fn scan_library(&self, library: &Library) {
        let tx = self.tx.clone();
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
                    Self::scan_tv_shows(lib_path, tx).await;
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

                if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
                    let lower_ext = ext.to_lowercase();
                    match lower_ext.as_str() {
                        "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv" => {
                            if !has_metadata(&path) {
                                println!(
                                    "[scanner] Queueing missing metadata (Movie): {:?}",
                                    path.file_name()
                                );
                                if let Err(e) = tx.send(ScanTask { path, is_tv: false }).await {
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

    async fn scan_tv_shows(lib_path: PathBuf, tx: mpsc::Sender<ScanTask>) {
        let mut entries = match tokio::fs::read_dir(&lib_path).await {
            Ok(e) => e,
            Err(e) => {
                eprintln!("[scanner] Failed to read TV dir {:?}: {}", lib_path, e);
                return;
            }
        };

        while let Ok(Some(entry)) = entries.next_entry().await {
            // Yield per entry to be polite
            tokio::task::yield_now().await;

            let path = entry.path();
            // TV Shows: we only look at top-level directories
            if path.is_dir() {
                if !has_metadata(&path) {
                    println!(
                        "[scanner] Queueing missing metadata (TV Show): {:?}",
                        path.file_name()
                    );
                    // For directories, process_file will use directory name as query
                    if let Err(e) = tx.send(ScanTask { path, is_tv: true }).await {
                        eprintln!("[scanner] Failed to queue item: {}", e);
                        break;
                    }
                    sleep(Duration::from_millis(10)).await;
                }
            }
        }
        println!("[scanner] Finished scanning TV Shows library");
    }
}

fn has_metadata(video_path: &Path) -> bool {
    let file_name = match video_path.file_name() {
        Some(n) => n.to_string_lossy(),
        None => return false,
    };

    // For TV shows (directories), we look for metadata inside the directory?
    // Or sidecar next to the directory?
    // User said: "metadata should be fetched... [for] media files without corresponding json and jpg"
    // For Shows, "1st level folders that are named after the shows".
    // Usually Sratim puts metadata INSIDE the show folder for the show itself?
    // Or sidecar to the folder?
    // `read_local_metadata` checks `parent.join(format!("{}.json", file_name))`.
    // If probing a directory `/path/to/Show`, file_name is `Show`. Parent is `/path/to`.
    // So it expects `/path/to/Show.json`.

    // Let's verify `has_metadata` logic matches `read_local_metadata` expectations.

    let parent = video_path.parent();
    if parent.is_none() {
        return false;
    }
    let parent = parent.unwrap();

    let json_path = parent.join(format!("{}.json", file_name));
    let jpg_path = parent.join(format!("{}.jpg", file_name));

    json_path.exists() && jpg_path.exists()
}
