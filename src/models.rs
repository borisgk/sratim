use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use turso::Builder;

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
    pub async fn load() -> Result<Self> {
        let db_path = default_data_dir().join("config.db");
        
        let db_dir = db_path.parent().unwrap_or(std::path::Path::new(""));
        if !db_dir.exists() && db_dir != std::path::Path::new("") {
            tokio::fs::create_dir_all(db_dir)
                .await
                .context("Failed to create db dir")?;
        }

        let db = Builder::new_local(&db_path.to_string_lossy())
            .build()
            .await
            .context("Failed to build local db")?;

        let conn = db.connect().context("Failed to connect to local db")?;

        let migration = "
        CREATE TABLE IF NOT EXISTS config (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            frontend_dir TEXT NOT NULL,
            port INTEGER NOT NULL,
            host TEXT NOT NULL,
            tmdb_base_url TEXT NOT NULL,
            tmdb_image_base_url TEXT NOT NULL,
            tmdb_access_token TEXT NOT NULL,
            external_server_url TEXT,
            jwt_secret TEXT NOT NULL,
            data_dir TEXT NOT NULL
        );
        ";
        conn.execute(migration, ())
            .await
            .context("Failed to run config table migration")?;

        // Try to load from DB
        let mut stmt = conn
            .prepare("SELECT frontend_dir, port, host, tmdb_base_url, tmdb_image_base_url, tmdb_access_token, external_server_url, jwt_secret, data_dir FROM config WHERE id = 1")
            .await?;
        let mut rows = stmt.query(()).await?;

        if let Some(row) = rows.next().await? {
            let external_server_url: Option<String> = row.get(6).ok().flatten();
            return Ok(AppConfig {
                frontend_dir: PathBuf::from(row.get::<String>(0)?),
                port: row.get::<i64>(1)? as u16,
                host: row.get(2)?,
                tmdb_base_url: row.get(3)?,
                tmdb_image_base_url: row.get(4)?,
                tmdb_access_token: row.get(5)?,
                external_server_url,
                jwt_secret: row.get(7)?,
                data_dir: PathBuf::from(row.get::<String>(8)?),
            });
        }

        // Drop the statements so we can insert into the db without locking issues
        drop(rows);
        drop(stmt);

        // If not in DB, migrate from config.toml or use defaults
        let mut config = None;
        let config_paths = [
            PathBuf::from("config.toml"),
            PathBuf::from("/etc/sratim/config.toml"),
            PathBuf::from("/usr/local/etc/sratim/config.toml"),
        ];

        for path in &config_paths {
            if path.exists() {
                println!("Migrating configuration from old TOML: {:?}", path);
                if let Ok(content) = fs::read_to_string(path) {
                    if let Ok(parsed) = toml::from_str::<AppConfig>(&content) {
                        config = Some(parsed);
                    }
                }

                // Delete the old config.toml
                if let Err(e) = fs::remove_file(path) {
                    eprintln!("Failed to delete old config file {:?}: {}", path, e);
                }

                // If in /etc/sratim or /usr/local/etc/sratim, try to remove the directory
                if path.starts_with("/etc/sratim") || path.starts_with("/usr/local/etc/sratim") {
                    if let Some(parent) = path.parent() {
                        let _ = fs::remove_dir(parent); // Ignore errors if not empty
                    }
                }
            }
        }

        let config = config.unwrap_or_else(|| {
            println!("No config file found, generating default settings into config.db");
            Self::default_settings()
        });

        // Insert into DB
        let external_server_val = match &config.external_server_url {
            Some(url) if !url.is_empty() => turso::Value::Text(url.clone()),
            _ => turso::Value::Null,
        };

        let mut insert_stmt = conn.prepare("
            INSERT INTO config (id, frontend_dir, port, host, tmdb_base_url, tmdb_image_base_url, tmdb_access_token, external_server_url, jwt_secret, data_dir)
            VALUES (1, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
        ").await?;

        insert_stmt.execute(turso::params![
            config.frontend_dir.to_string_lossy().to_string(),
            turso::Value::Integer(config.port as i64),
            config.host.clone(),
            config.tmdb_base_url.clone(),
            config.tmdb_image_base_url.clone(),
            config.tmdb_access_token.clone(),
            external_server_val,
            config.jwt_secret.clone(),
            config.data_dir.to_string_lossy().to_string(),
        ]).await.context("Failed to insert config")?;

        Ok(config)
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
