use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

// --- Config ---

#[derive(Debug, Deserialize, Serialize, Clone)]
pub struct AppConfig {
    #[serde(default = "default_frontend_dir")]
    pub frontend_dir: PathBuf,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_host")]
    pub host: String,
    #[serde(default = "default_tmdb_base_url")]
    pub tmdb_base_url: String,
    #[serde(default = "default_tmdb_image_base_url")]
    pub tmdb_image_base_url: String,
    #[serde(default)]
    pub tmdb_access_token: String,
    #[serde(default)]
    pub external_server_url: Option<String>,
    #[serde(default = "default_jwt_secret")]
    pub jwt_secret: String,
    #[serde(default = "default_data_dir")]
    pub data_dir: PathBuf,
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

fn default_data_dir() -> PathBuf {
    if PathBuf::from("/var/lib/sratim").is_dir() {
        PathBuf::from("/var/lib/sratim")
    } else {
        PathBuf::from(".")
    }
}

fn default_tmdb_base_url() -> String {
    "https://api.themoviedb.org/3".to_string()
}

fn default_tmdb_image_base_url() -> String {
    "https://image.tmdb.org/t/p/w500".to_string()
}

fn default_jwt_secret() -> String {
    "change_me_in_production_use_a_long_random_string".to_string()
}

impl AppConfig {
    pub fn load() -> Result<Self> {
        let config_paths = [
            PathBuf::from("config.toml"),
            PathBuf::from("/etc/sratim/config.toml"),
            PathBuf::from("/usr/local/etc/sratim/config.toml"),
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
        let default_config = Self::default_settings();

        // Determine where to write the default configuration
        let target_path = if PathBuf::from("/etc/sratim").is_dir() {
            PathBuf::from("/etc/sratim/config.toml")
        } else if PathBuf::from("/usr/local/etc/sratim").is_dir() {
            PathBuf::from("/usr/local/etc/sratim/config.toml")
        } else {
            PathBuf::from("config.toml")
        };

        println!("Creating a new default configuration at: {:?}", target_path);
        let toml_string = toml::to_string_pretty(&default_config)
            .context("Failed to serialize default configuration")?;

        // Ensure parent directory exists
        if let Some(parent) = target_path.parent() {
            if !parent.exists() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("Failed to create directory: {:?}", parent))?;
            }
        }

        fs::write(&target_path, toml_string)
            .with_context(|| format!("Failed to write default configuration to {:?}", target_path))?;

        Ok(default_config)
    }

    fn default_settings() -> Self {
        Self {
            frontend_dir: default_frontend_dir(),
            port: default_port(),
            host: default_host(),
            tmdb_base_url: default_tmdb_base_url(),
            tmdb_image_base_url: default_tmdb_image_base_url(),
            tmdb_access_token: String::new(),
            external_server_url: None,
            jwt_secret: default_jwt_secret(),
            data_dir: default_data_dir(),
        }
    }
}

// --- State ---

#[derive(Clone)]
pub struct AppState {
    pub auth: crate::auth::AuthState,
    pub libraries: Arc<tokio::sync::RwLock<Vec<Library>>>,
    pub config: AppConfig,
    pub scanner: Arc<crate::scanner::Scanner>,
    pub db: Arc<crate::db::DbClient>,
}

// --- Library Models ---

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub enum LibraryType {
    Movies,
    TVShows,
    Other,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Library {
    pub id: String,
    pub name: String,
    pub path: PathBuf,
    pub kind: LibraryType,
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
    pub library_id: Option<String>,
}

#[derive(Deserialize)]
pub struct MetadataParams {
    pub path: String,
    pub library_id: Option<String>,
}

#[derive(Deserialize)]
pub struct SubtitleParams {
    pub path: String,
    pub index: usize,
    pub library_id: Option<String>,
}

// --- Handler Models ---

#[derive(Deserialize)]
pub struct ListParams {
    #[serde(default)]
    pub path: String,
    pub library_id: Option<String>,
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
    pub library_id: Option<String>,
}
