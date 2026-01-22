use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::process::Child;
use tokio::sync::Mutex;

// --- Config ---

#[derive(Debug, Deserialize, Clone)]
pub struct AppConfig {
    #[serde(default = "default_movies_dir")]
    pub movies_dir: PathBuf,
    #[serde(default = "default_frontend_dir")]
    pub frontend_dir: PathBuf,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_host")]
    pub host: String,
    pub tmdb_api_key: Option<String>,
}

fn default_movies_dir() -> PathBuf {
    PathBuf::from("movies")
}

fn default_frontend_dir() -> PathBuf {
    PathBuf::from("frontend")
}

fn default_port() -> u16 {
    3000
}

fn default_host() -> String {
    "0.0.0.0".to_string()
}

impl AppConfig {
    pub fn load() -> Result<Self> {
        let config_paths = [
            PathBuf::from("config.toml"),
            PathBuf::from("/usr/local/etc/sratim/config.toml"),
            PathBuf::from("/etc/sratim/config.toml"),
        ];

        for path in &config_paths {
            if path.exists() {
                println!("Loading configuration from: {:?}", path);
                let content = fs::read_to_string(path)
                    .with_context(|| format!("Failed to read config file: {:?}", path))?;
                let config: AppConfig = toml::from_str(&content)
                    .with_context(|| format!("Failed to parse TOML in: {:?}", path))?;
                return Ok(config);
            }
        }

        println!("No config file found, using default settings.");
        Ok(Self::default_settings())
    }

    fn default_settings() -> Self {
        Self {
            movies_dir: default_movies_dir(),
            frontend_dir: default_frontend_dir(),
            port: default_port(),
            host: default_host(),
            tmdb_api_key: None,
        }
    }
}

// --- State ---

#[derive(Clone)]
pub struct AppState {
    pub movies_dir: PathBuf,
    pub dash_temp_dir: PathBuf,
    pub ffmpeg_process: Arc<Mutex<Option<Child>>>,
    pub tmdb_api_key: Option<String>,
}

// --- Models ---

#[derive(Serialize)]
pub struct AudioTrack {
    pub index: usize,
    pub language: Option<String>,
    pub label: Option<String>,
    pub codec: String,
    pub channels: Option<usize>,
}

#[derive(Serialize)]
pub struct SubtitleTrack {
    pub index: usize,
    pub language: Option<String>,
    pub label: Option<String>,
    pub codec: String,
}

#[derive(Serialize)]
pub struct MovieMetadata {
    pub duration: f64,
    pub video_codec: String,
    pub title: Option<String>,
    pub audio_tracks: Vec<AudioTrack>,
    pub subtitle_tracks: Vec<SubtitleTrack>,
}

#[derive(Deserialize)]
pub struct StreamParams {
    pub path: String,
    #[serde(default)]
    pub start: f64,
    #[serde(default)]
    pub audio_track: Option<usize>,
}

#[derive(Deserialize)]
pub struct MetadataParams {
    pub path: String,
}

#[derive(Deserialize)]
pub struct SubtitleParams {
    pub path: String,
    pub index: usize,
}

// --- Handler Models ---

#[derive(Deserialize)]
pub struct ListParams {
    #[serde(default)]
    pub path: String,
}

#[derive(Serialize)]
pub struct FileEntry {
    pub name: String,
    pub path: String,
    #[serde(rename = "type")]
    pub entry_type: String, // "folder" or "file"
    pub title: Option<String>,
    pub poster: Option<String>,
}

#[derive(Deserialize)]
pub struct LookupParams {
    pub path: String,
}
