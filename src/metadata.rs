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
    results: Vec<TmdbResult>,
}

#[derive(Debug, Deserialize)]
struct TmdbResult {
    id: u64,
    #[serde(alias = "name")]
    title: String,
    overview: String,
    poster_path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct TmdbSeasonResponse {
    id: u64,
    name: String,
    overview: String,
    poster_path: Option<String>,
}

pub async fn read_local_metadata(path: &Path) -> Option<LocalMetadata> {
    let file_name = path.file_name()?.to_string_lossy();
    let parent = path.parent()?;
    let json_path = parent.join(format!("{}.json", file_name));

    if json_path.exists()
        && let Ok(content) = fs::read_to_string(&json_path).await
        && let Ok(meta) = serde_json::from_str::<LocalMetadata>(&content)
    {
        return Some(meta);
    }
    None
}

pub async fn save_local_metadata(path: &Path, metadata: &LocalMetadata) -> Result<()> {
    let file_name = path.file_name().context("No filename")?.to_string_lossy();
    let parent = path.parent().context("No parent")?;
    let json_path = parent.join(format!("{}.json", file_name));

    let content = serde_json::to_string_pretty(metadata)?;
    fs::write(json_path, content)
        .await
        .context("Failed to write metadata json")
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

pub async fn fetch_tmdb_metadata(
    query: &str,
    year: Option<&str>,
    is_tv: bool,
    api_key: Option<&str>,
    base_url: &str,
) -> Result<Option<LocalMetadata>> {
    let client = reqwest::Client::new();
    let endpoint = if is_tv { "tv" } else { "movie" };
    let year_param = if is_tv { "first_air_date_year" } else { "year" };

    let mut url = format!(
        "{}/search/{}?query={}&language=en-US&page=1&include_adult=false",
        base_url,
        endpoint,
        urlencoding::encode(query)
    );

    if let Some(y) = year {
        url.push_str(&format!("&{}={}", year_param, y));
    }

    if let Some(key) = api_key {
        url.push_str(&format!("&api_key={}", key));
    }

    println!(
        "[metadata] Searching TMDB ({}) for: '{}' (Year: {:?})",
        endpoint, query, year
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

pub async fn fetch_tmdb_season_metadata(
    tmdb_id: u64,
    season_number: u32,
    api_key: Option<&str>,
    base_url: &str,
) -> Result<Option<LocalMetadata>> {
    let client = reqwest::Client::new();
    let mut url = format!(
        "{}/tv/{}/season/{}?language=en-US",
        base_url, tmdb_id, season_number
    );

    if let Some(key) = api_key {
        url.push_str(&format!("&api_key={}", key));
    }

    println!(
        "[metadata] Fetching TMDB Season: Show={}, Season={}",
        tmdb_id, season_number
    );
    println!("[metadata] Request URL: {}", url);

    let resp = client
        .get(&url)
        .header("Accept", "application/json")
        .header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
        .send()
        .await
        .context("Failed to send TMDB season request")?;

    println!("[metadata] Response status: {}", resp.status());

    if !resp.status().is_success() {
        if resp.status() == 404 {
            return Ok(None);
        }
        let error_text = resp.text().await.unwrap_or_else(|_| "Unknown error".into());
        println!("[metadata] API Error Body: {}", error_text);
        return Err(anyhow::anyhow!("TMDB API Error"));
    }

    let season_res: TmdbSeasonResponse =
        resp.json().await.context("Failed to parse TMDB response")?;

    Ok(Some(LocalMetadata {
        title: season_res.name,
        overview: season_res.overview,
        poster_path: season_res.poster_path,
        tmdb_id: season_res.id,
    }))
}

pub async fn download_image(poster_suffix: &str, target_path: &Path, api_key: Option<&str>) -> Result<()> {
    let base = if api_key.is_some() {
        "https://image.tmdb.org/t/p/w500"
    } else {
        "https://glossary.rus9n.com/t/p/w500"
    };
    let url = format!("{}{}", base, poster_suffix);
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
            (
                "Another Movie (1999) [Bluray]",
                "Another Movie",
                Some("1999"),
            ),
            ("No Year Movie", "No Year Movie", None),
            (
                "Complex.Movie.Name.2022.PROPER.1080p.WEB-DL.H264-Release",
                "Complex Movie Name",
                Some("2022"),
            ),
            (
                "Movie_With_Underscores_2020",
                "Movie With Underscores",
                Some("2020"),
            ),
            (
                "Movie.Title.With.Many.Dots.2021",
                "Movie Title With Many Dots",
                Some("2021"),
            ),
        ];

        for (input, expected_title, expected_year) in cases {
            let (title, year) = cleanup_filename(input);
            assert_eq!(
                title, expected_title,
                "Failed on title for input: {}",
                input
            );
            assert_eq!(
                year.as_deref(),
                expected_year,
                "Failed on year for input: {}",
                input
            );
        }
    }
}
