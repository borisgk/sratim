use anyhow::{Context, Result};
use libsql::{Builder, Connection, Database};
use std::path::PathBuf;

use crate::metadata::LocalMetadata;

pub struct DbClient {
    pub db: Database,
    pub conn: Connection,
}

impl DbClient {
    pub async fn init(db_path: PathBuf) -> Result<Self> {
        let db_dir = db_path.parent().unwrap_or(std::path::Path::new(""));
        if !db_dir.exists() && db_dir != std::path::Path::new("") {
            tokio::fs::create_dir_all(db_dir)
                .await
                .context("Failed to create db dir")?;
        }

        let db = Builder::new_local(db_path.to_string_lossy().to_string())
            .build()
            .await
            .context("Failed to build local db")?;

        let conn = db.connect().context("Failed to connect to local db")?;

        let client = Self { db, conn };

        let migration = "
        CREATE TABLE IF NOT EXISTS metadata (
            path TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            overview TEXT NOT NULL,
            poster_path TEXT,
            tmdb_id INTEGER NOT NULL,
            episode_number INTEGER
        );
        ";
        client
            .conn
            .execute(migration, ())
            .await
            .context("Failed to run metadata table migration")?;

        Ok(client)
    }

    pub async fn get_metadata(&self, path: &str) -> Result<Option<LocalMetadata>> {
        let stmt = self.conn.prepare("SELECT title, overview, poster_path, tmdb_id, episode_number FROM metadata WHERE path = ?1").await?;
        let mut rows = stmt.query([path]).await?;

        if let Some(row) = rows.next().await? {
            let title: String = row.get(0)?;
            let overview: String = row.get(1)?;
            let poster_path: Option<String> = row.get(2).ok().flatten();
            let tmdb_id: i64 = row.get(3)?;
            let episode_number: Option<i64> = row.get(4).ok().flatten();

            Ok(Some(LocalMetadata {
                title,
                overview,
                poster_path,
                tmdb_id: tmdb_id as u64,
                episode_number: episode_number.map(|e| e as u32),
            }))
        } else {
            Ok(None)
        }
    }

    pub async fn save_metadata(&self, path: &str, metadata: &LocalMetadata) -> Result<()> {
        let stmt = self
            .conn
            .prepare(
                "
            INSERT INTO metadata (path, title, overview, poster_path, tmdb_id, episode_number)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(path) DO UPDATE SET
                title = excluded.title,
                overview = excluded.overview,
                poster_path = excluded.poster_path,
                tmdb_id = excluded.tmdb_id,
                episode_number = excluded.episode_number
        ",
            )
            .await?;

        let poster_path_val = match &metadata.poster_path {
            Some(p) => p.clone(),
            None => "".to_string(), // we can handle null if we use Option, but we can also just use empty
        };
        let episode_val = match metadata.episode_number {
            Some(e) => e as i64,
            None => -1, // representing null instead
        };

        // Actually it's cleaner to handle option manually with libsql::params!
        let poster_val = if poster_path_val.is_empty() {
            libsql::Value::Null
        } else {
            libsql::Value::Text(poster_path_val)
        };
        let episode_val2 = if episode_val == -1 {
            libsql::Value::Null
        } else {
            libsql::Value::Integer(episode_val)
        };

        stmt.execute(libsql::params![
            path.to_string(),
            metadata.title.clone(),
            metadata.overview.clone(),
            poster_val,
            libsql::Value::Integer(metadata.tmdb_id as i64),
            episode_val2
        ])
        .await?;

        Ok(())
    }
}
