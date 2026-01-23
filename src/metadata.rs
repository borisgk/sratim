use anyhow::{Context, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::Path;
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
    // 1. Find the year (19xx or 20xx)
    let year_re = Regex::new(r"[\(\[\.]*(19|20)\d{2}[\)\]\.]*").unwrap();

    let (base_name, year) = if let Some(mat) = year_re.find(filename) {
        // Extract year string (clean it of brackets/dots)
        let raw_year = mat.as_str();
        let clean_year_re = Regex::new(r"\d{4}").unwrap();
        let year_val = clean_year_re.find(raw_year).map(|m| m.as_str().to_string());

        // Keep everything up to the START of the year match for title
        let start = mat.start();
        (&filename[..start], year_val)
    } else {
        (filename, None)
    };

    // 2. Remove tags from the remaining base_name
    let re = Regex::new(r"(?i)[\s\.]*(1080p|720p|4k|2160p|bluray|web-dl|webrip|remux|hdr|x264|x265|hevc|aac|ac3|dts|eng|sub|subs)[\s\.]*").unwrap();
    let no_tags = re.replace_all(base_name, " ");

    // 3. Cleanup dots/underscores
    let clean = no_tags.replace(['.', '_', '(', ')', '[', ']'], " ");

    // 4. Trim spaces
    let space_re = Regex::new(r"\s+").unwrap();
    let final_title = space_re.replace_all(&clean, " ").trim().to_string();

    (final_title, year)
}

pub async fn fetch_tmdb_metadata(query: &str, year: Option<&str>) -> Result<Option<LocalMetadata>> {
    let client = reqwest::Client::new();
    let mut url = format!(
        "https://glossary.rus9n.com/3/search/movie?query={}&language=en-US&page=1&include_adult=false",
        urlencoding::encode(query)
    );

    if let Some(y) = year {
        url.push_str(&format!("&year={}", y));
    }

    println!(
        "[metadata] Searching TMDB for: '{}' (Year: {:?})",
        query, year
    );
    println!("[metadata] Request URL: {}", url);
    println!("[metadata] Request Headers: Accept: application/json");

    let resp = client
        .get(&url)
        .header("Accept", "application/json")
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
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
    let url = format!("https://glossary.rus9n.com/t/p/w500{}", poster_suffix);
    println!("[metadata] Downloading image from: {}", url);

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .context("Failed to build HTTP client")?;

    let resp = client
        .get(&url)
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .send()
        .await
        .context("Failed to download image")?;

    let bytes = resp.bytes().await.context("Failed to get image bytes")?;
    println!("[metadata] Downloaded {} bytes", bytes.len());

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
    fn test_cleanup_filename() {
        let cases = vec![
            ("Movie.Title.2023.1080p.mkv", "Movie Title", Some("2023")),
            ("Another Movie (1999) [Bluray]", "Another Movie", Some("1999")),
            ("No Year Movie", "No Year Movie", None),
            ("Complex.Movie.Name.2022.PROPER.1080p.WEB-DL.H264-Release", "Complex Movie Name", Some("2022")),
            ("Movie_With_Underscores_2020", "Movie With Underscores", Some("2020")),
            ("Movie.Title.With.Many.Dots.2021", "Movie Title With Many Dots", Some("2021")),
        ];

        for (input, expected_title, expected_year) in cases {
            let (title, year) = cleanup_filename(input);
            assert_eq!(title, expected_title, "Failed on title for input: {}", input);
            assert_eq!(year.as_deref(), expected_year, "Failed on year for input: {}", input);
        }
    }
}
