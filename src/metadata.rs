use anyhow::{Context, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::OnceLock;
use tokio::fs;
use tokio::io::AsyncWriteExt;

#[derive(Debug, Serialize, Deserialize)]
pub struct LocalMetadata {
    pub title: String,
    pub overview: String,
    pub poster_path: Option<String>,
    pub tmdb_id: u64,
}

#[derive(Debug, Deserialize)]
struct TmdbSearchResponse {
    results: Vec<TmdbMovie>,
}

#[derive(Debug, Deserialize)]
struct TmdbMovie {
    id: u64,
    title: String,
    overview: String,
    poster_path: Option<String>,
}

pub fn cleanup_filename(filename: &str) -> (String, Option<String>) {
    // Remove extension first
    let filename_no_ext = Path::new(filename)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or(filename);

    // 1. Find the year (19xx or 20xx)
    static YEAR_RE: OnceLock<Regex> = OnceLock::new();
    let year_re = YEAR_RE.get_or_init(|| Regex::new(r"[\(\[\.]*(19|20)\d{2}[\)\]\.]*").unwrap());

    let (base_name, year) = if let Some(mat) = year_re.find(filename_no_ext) {
        // Extract year string (clean it of brackets/dots)
        let raw_year = mat.as_str();

        static CLEAN_YEAR_RE: OnceLock<Regex> = OnceLock::new();
        let clean_year_re = CLEAN_YEAR_RE.get_or_init(|| Regex::new(r"\d{4}").unwrap());

        let year_val = clean_year_re.find(raw_year).map(|m| m.as_str().to_string());

        // Keep everything up to the START of the year match for title
        let start = mat.start();
        (&filename_no_ext[..start], year_val)
    } else {
        (filename_no_ext, None)
    };

    // 2. Remove tags from the remaining base_name
    static TAGS_RE: OnceLock<Regex> = OnceLock::new();
    let re = TAGS_RE.get_or_init(|| {
        Regex::new(r"(?i)[\s\.]*(1080p|720p|4k|2160p|bluray|web-dl|webrip|remux|hdr|x264|x265|hevc|aac|ac3|dts|eng|sub|subs)[\s\.]*").unwrap()
    });
    let no_tags = re.replace_all(base_name, " ");

    // 3. Cleanup dots/underscores
    let clean = no_tags.replace(['.', '_', '(', ')', '[', ']'], " ");

    // 4. Trim spaces
    static SPACE_RE: OnceLock<Regex> = OnceLock::new();
    let space_re = SPACE_RE.get_or_init(|| Regex::new(r"\s+").unwrap());
    let final_title = space_re.replace_all(&clean, " ").trim().to_string();

    (final_title, year)
}

pub async fn fetch_tmdb_metadata(
    query: &str,
    year: Option<&str>,
    access_token: &str,
) -> Result<Option<LocalMetadata>> {
    let client = reqwest::Client::new();
    let mut url = format!(
        "https://api.themoviedb.org/3/search/movie?query={}&language=en-US&page=1&include_adult=false",
        urlencoding::encode(query)
    );

    if let Some(y) = year {
        url.push_str(&format!("&year={}", y));
    }

    println!(
        "[metadata] Searching TMDB for: '{}' (Year: {:?})",
        query, year
    );

    let resp = client
        .get(&url)
        .header("Authorization", format!("Bearer {}", access_token))
        .header("Accept", "application/json")
        .send()
        .await
        .context("Failed to send TMDB request")?;

    println!("[metadata] Response status: {}", resp.status());

    if !resp.status().is_success() {
        let error_text = resp.text().await.unwrap_or_else(|_| "Unknown error".into());
        println!("[metadata] API Error Body: {}", error_text);
        return Err(anyhow::anyhow!("TMDB API Error"));
    }

    let search_res: TmdbSearchResponse =
        resp.json().await.context("Failed to parse TMDB response")?;

    println!("[metadata] Found {} results", search_res.results.len());
    if let Some(first) = search_res.results.first() {
        println!("[metadata] Top match: {} ({})", first.title, first.id);
    }

    if let Some(movie) = search_res.results.into_iter().next() {
        Ok(Some(LocalMetadata {
            title: movie.title,
            overview: movie.overview,
            poster_path: movie.poster_path,
            tmdb_id: movie.id,
        }))
    } else {
        Ok(None)
    }
}

pub async fn download_image(poster_suffix: &str, target_path: &Path) -> Result<()> {
    let url = format!("https://image.tmdb.org/t/p/w500{}", poster_suffix);
    println!("[metadata] Downloading image from: {}", url);

    let resp = reqwest::get(&url)
        .await
        .context("Failed to download image")?;
    let bytes = resp.bytes().await.context("Failed to get image bytes")?;

    let mut file = fs::File::create(target_path)
        .await
        .context("Failed to create image file")?;
    file.write_all(&bytes)
        .await
        .context("Failed to write image data")?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cleanup_filename_standard() {
        let (title, year) = cleanup_filename("Inception.2010.1080p.Bluray.x264.mkv");
        assert_eq!(title, "Inception");
        assert_eq!(year, Some("2010".to_string()));
    }

    #[test]
    fn test_cleanup_filename_with_brackets() {
        let (title, year) = cleanup_filename("The.Matrix.[1999].4k.HDR.mkv");
        assert_eq!(title, "The Matrix");
        assert_eq!(year, Some("1999".to_string()));
    }

    #[test]
    fn test_cleanup_filename_no_year() {
        let (title, year) = cleanup_filename("My.Home.Movie.1080p.mp4");
        assert_eq!(title, "My Home Movie");
        assert_eq!(year, None);
    }

    #[test]
    fn test_cleanup_filename_underscores() {
        let (title, year) = cleanup_filename("Spider_Man_No_Way_Home_2021_WebRip.mp4");
        assert_eq!(title, "Spider Man No Way Home");
        assert_eq!(year, Some("2021".to_string()));
    }

    #[test]
    fn test_cleanup_filename_simple() {
        let (title, year) = cleanup_filename("Avatar (2009)");
        assert_eq!(title, "Avatar");
        assert_eq!(year, Some("2009".to_string()));
    }
}
