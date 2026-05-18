use anyhow::{Context, Result};
use std::path::PathBuf;
use turso::{Builder, Database};

use crate::metadata::LocalMetadata;

pub struct DbClient {
    pub db: Database,
}

impl DbClient {
    pub async fn init(db_path: PathBuf) -> Result<Self> {
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

        let client = Self { db };

        let conn = client
            .db
            .connect()
            .context("Failed to connect to local db")?;

        let migration = "
        CREATE TABLE IF NOT EXISTS metadata (
            path TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            overview TEXT NOT NULL,
            poster_path TEXT,
            tmdb_id INTEGER NOT NULL,
            episode_number INTEGER,
            added_at DATETIME DEFAULT CURRENT_TIMESTAMP
        );
        ";
        conn.execute(migration, ())
            .await
            .context("Failed to run metadata table migration")?;

        // Add column if migrating from previous DB version
        let _ = conn
            .execute("ALTER TABLE metadata ADD COLUMN added_at DATETIME", ())
            .await;

        Ok(client)
    }

    pub async fn get_metadata(&self, path: &str) -> Result<Option<LocalMetadata>> {
        let conn = self.db.connect().context("Failed to open db connection")?;

        let mut stmt = conn.prepare("SELECT title, overview, poster_path, tmdb_id, episode_number, added_at FROM metadata WHERE path = ?1").await?;
        let mut rows = stmt.query([path]).await?;

        if let Some(row) = rows.next().await? {
            let title: String = row.get(0)?;
            let overview: String = row.get(1)?;
            let poster_path: Option<String> = row.get(2).ok().flatten();
            let tmdb_id: i64 = row.get(3)?;
            let episode_number: Option<i64> = row.get(4).ok().flatten();
            let added_at: Option<String> = row.get(5).ok().flatten();

            Ok(Some(LocalMetadata {
                title,
                overview,
                poster_path,
                tmdb_id: tmdb_id as u64,
                episode_number: episode_number.map(|e| e as u32),
                added_at,
            }))
        } else {
            Ok(None)
        }
    }

    pub async fn get_movies_for_library(&self, library_path: &str) -> Result<Vec<(String, LocalMetadata)>> {
        let conn = self.db.connect().context("Failed to open db connection")?;
        
        let query_path = format!("{}%", library_path);
        let mut stmt = conn
            .prepare("SELECT path, title, overview, poster_path, tmdb_id, episode_number, added_at FROM metadata WHERE path LIKE ?1")
            .await?;
        let mut rows = stmt.query([query_path]).await?;

        let mut movies = Vec::new();
        while let Some(row) = rows.next().await? {
            let path: String = row.get(0)?;
            let title: String = row.get(1)?;
            let overview: String = row.get(2)?;
            let poster_path: Option<String> = row.get(3).ok().flatten();
            let tmdb_id: i64 = row.get(4)?;
            let episode_number: Option<i64> = row.get(5).ok().flatten();
            let added_at: Option<String> = row.get(6).ok().flatten();

            movies.push((path, LocalMetadata {
                title,
                overview,
                poster_path,
                tmdb_id: tmdb_id as u64,
                episode_number: episode_number.map(|e| e as u32),
                added_at,
            }));
        }
        
        Ok(movies)
    }

    pub async fn save_metadata(&self, path: &str, metadata: &LocalMetadata) -> Result<()> {
        let conn = self.db.connect().context("Failed to open db connection")?;

        let mut stmt = conn
            .prepare(
                "
            INSERT INTO metadata (path, title, overview, poster_path, tmdb_id, episode_number, added_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, datetime('now'))
            ON CONFLICT(path) DO UPDATE SET
                title = excluded.title,
                overview = excluded.overview,
                poster_path = excluded.poster_path,
                tmdb_id = excluded.tmdb_id,
                episode_number = excluded.episode_number
        ",
            )
            .await?;

        let poster_val = match &metadata.poster_path {
            Some(p) if !p.is_empty() => turso::Value::Text(p.clone()),
            _ => turso::Value::Null,
        };

        let episode_val = match metadata.episode_number {
            Some(e) => turso::Value::Integer(e as i64),
            None => turso::Value::Null,
        };

        stmt.execute(turso::params![
            path.to_string(),
            metadata.title.clone(),
            metadata.overview.clone(),
            poster_val,
            turso::Value::Integer(metadata.tmdb_id as i64),
            episode_val
        ])
        .await?;

        Ok(())
    }

    pub async fn clean_orphaned_metadata(&self, library_path: &str) -> Result<()> {
        let conn = self.db.connect().context("Failed to open db connection")?;

        let query_path = format!("{}%", library_path);
        let mut stmt = conn
            .prepare("SELECT path FROM metadata WHERE path LIKE ?1")
            .await?;
        let mut rows = stmt.query([query_path]).await?;

        let mut to_delete = Vec::new();
        while let Some(row) = rows.next().await? {
            let path: String = row.get(0)?;
            if !std::path::Path::new(&path).exists() {
                to_delete.push(path);
            }
        }

        // Drop the read statement before opening write statements
        drop(rows);
        drop(stmt);

        for p in to_delete {
            println!("[db] Removing orphaned metadata for missing file: {}", p);
            let del_conn = self.db.connect().context("Failed to open db connection")?;
            let mut del_stmt = del_conn
                .prepare("DELETE FROM metadata WHERE path = ?1")
                .await?;
            del_stmt.execute([p]).await?;
        }

        Ok(())
    }
}
