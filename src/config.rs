use anyhow::{Context, Result};
use serde::Deserialize;
use std::fs;
use std::path::PathBuf;

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
        }
    }
}
