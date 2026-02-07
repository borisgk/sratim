use std::path::{Path, PathBuf};
use tokio::sync::mpsc;
use tokio::time::{Duration, sleep};

use crate::metadata::process_file;
use crate::models::{AppConfig, Library, LibraryType};

pub struct Scanner {
    tx: mpsc::Sender<PathBuf>,
}

impl Scanner {
    pub fn new(config: AppConfig) -> (Self, tokio::task::JoinHandle<()>) {
        let (tx, mut rx) = mpsc::channel::<PathBuf>(100);

        let worker_handle = tokio::spawn(async move {
            println!("[scanner] Background worker started");
            while let Some(path) = rx.recv().await {
                println!("[scanner] Worker picked up: {:?}", path);

                // Rate limiting to be polite to TMDB
                sleep(Duration::from_millis(500)).await;

                // Process
                // We assume Movies for now as per task description
                if let Err(e) = process_file(&path, &config, false).await {
                    eprintln!("[scanner] Error processing {:?}: {}", path, e);
                }
            }
            println!("[scanner] Background worker stopped");
        });

        (Self { tx }, worker_handle)
    }

    pub async fn scan_library(&self, library: &Library) {
        if library.kind != LibraryType::Movies {
            println!("[scanner] Skipping non-movie library: {}", library.name);
            return;
        }

        println!(
            "[scanner] Scanning library: {} ({:?})",
            library.name, library.path
        );
        let tx = self.tx.clone();
        let lib_path = library.path.clone();

        tokio::spawn(async move {
            let mut dirs = vec![lib_path];

            while let Some(dir) = dirs.pop() {
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
                                // Check for sidecars
                                if !has_metadata(&path) {
                                    println!(
                                        "[scanner] Queueing missing metadata: {:?}",
                                        path.file_name()
                                    );
                                    if let Err(e) = tx.send(path).await {
                                        eprintln!("[scanner] Failed to queue item: {}", e);
                                        break;
                                    }
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
            println!("[scanner] Finished scanning library dir");
        });
    }
}

fn has_metadata(video_path: &Path) -> bool {
    // Check if .json exists (we focus on data primarily)
    // The user said: "without corresponding json and jpg"
    // Let's check both. If EITHER is missing, we might want to re-scan.
    // But usually JSON drives the title.
    // Let's stick to: if JSON exists, we assume we have metadata.
    // Re-downloading JPG just because it's missing might be a separate task,
    // but the prompt says "media files without corresponding json and jpg should be added".
    // I will queue if JSON is missing.

    // Actually, user said "without corresponding json and jpg".
    // Strict interpretation: both need to be present to skip.
    // If json is missing OR jpg is missing -> Queue.

    let file_name = match video_path.file_name() {
        Some(n) => n.to_string_lossy(),
        None => return false,
    };

    let json_path = video_path
        .parent()
        .unwrap()
        .join(format!("{}.json", file_name));
    let jpg_path = video_path
        .parent()
        .unwrap()
        .join(format!("{}.jpg", file_name));

    json_path.exists() && jpg_path.exists()
}
