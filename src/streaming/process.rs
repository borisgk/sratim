use crate::models::{AudioTrack, MovieMetadata, SubtitleTrack};
use anyhow::{Context, Result};
use axum::body::Bytes;
use futures_core::Stream;
use serde::Deserialize;
use std::path::Path;
use std::pin::Pin;
use std::process::Stdio;
use std::task::{Context as TaskContext, Poll};
use tokio::process::Child;
use tokio_util::io::ReaderStream;

// --- FFmpeg Spawning ---

pub fn spawn_ffmpeg(
    path: &Path,
    start: f64,
    audio_track_idx: Option<usize>,
    video_codec: &str,
) -> Result<Child> {
    let mut args = vec![
        "-noaccurate_seek".to_string(),
        "-ss".to_string(),
        start.to_string(),
        "-i".to_string(),
        path.to_string_lossy().to_string(),
        "-map".to_string(),
        "0:v:0".to_string(),
        "-c:v".to_string(),
        "copy".to_string(), // Enforce zero transcoding
    ];

    // HEVC tagging
    if video_codec == "hevc" {
        args.push("-tag:v".to_string());
        args.push("hvc1".to_string());
    }

    if let Some(track_idx) = audio_track_idx {
        args.extend_from_slice(&[
            "-map".to_string(),
            format!("0:a:{}", track_idx),
            "-c:a".to_string(),
            "aac".to_string(),
            "-ac".to_string(),
            "2".to_string(),
        ]);
    }

    args.extend_from_slice(&[
        "-movflags".to_string(),
        "frag_keyframe+empty_moov+default_base_moof".to_string(),
        "-f".to_string(),
        "mp4".to_string(),
        "pipe:1".to_string(),
    ]);

    println!("[stream] Spawning ffmpeg: {:?}", args);

    let mut command = tokio::process::Command::new("ffmpeg");
    command
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true); // Safety: kill if client disconnects

    let child = command.spawn().context("Failed to spawn ffmpeg")?;
    Ok(child)
}

pub fn extract_subtitle(path: &Path, subtitle_track_idx: usize) -> Result<Child> {
    let path_str = path.to_string_lossy().to_string();
    let map_arg = format!("0:s:{}", subtitle_track_idx);

    let args = vec![
        "-i",
        path_str.as_str(),
        "-map",
        map_arg.as_str(),
        "-c:s",
        "webvtt",
        "-f",
        "webvtt",
        "pipe:1",
    ];

    println!("[subtitle] Spawning ffmpeg: {:?}", args);

    let mut command = tokio::process::Command::new("ffmpeg");
    command
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped()) // Capture stderr to avoid polluting server logs, but maybe we don't need to read it
        .kill_on_drop(true);

    let child = command
        .spawn()
        .context("Failed to spawn ffmpeg for subtitles")?;
    Ok(child)
}

// --- Process Stream Wrapper ---

pub struct ProcessStream {
    stream: ReaderStream<tokio::process::ChildStdout>,
    _child: Child,
}

impl ProcessStream {
    pub fn new(stream: ReaderStream<tokio::process::ChildStdout>, child: Child) -> Self {
        Self {
            stream,
            _child: child,
        }
    }
}

impl Stream for ProcessStream {
    type Item = std::io::Result<Bytes>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<Option<Self::Item>> {
        Pin::new(&mut self.stream).poll_next(cx)
    }
}

// --- FFProbe Metadata ---

#[derive(Deserialize)]
struct FFProbeOutput {
    streams: Option<Vec<FFProbeStream>>,
    format: Option<FFProbeFormat>,
}

#[derive(Deserialize)]
struct FFProbeStream {
    #[serde(rename = "index")]
    _index: usize,
    codec_name: Option<String>,
    codec_type: String, // "video" or "audio"
    tags: Option<FFProbeTags>,
    channels: Option<usize>,
}

#[derive(Deserialize)]
struct FFProbeFormat {
    duration: Option<String>,
}

#[derive(Deserialize)]
struct FFProbeTags {
    language: Option<String>,
    title: Option<String>,
    label: Option<String>,
}

pub async fn probe_metadata(path: &Path) -> Result<MovieMetadata> {
    let output = tokio::process::Command::new("ffprobe")
        .args(&[
            "-v",
            "quiet",
            "-print_format",
            "json",
            "-show_streams",
            "-show_format",
        ])
        .arg(path)
        .output()
        .await
        .context("Failed to run ffprobe")?;

    if !output.status.success() {
        return Err(anyhow::anyhow!("ffprobe failed"));
    }

    let output_str = String::from_utf8_lossy(&output.stdout);
    let probe: FFProbeOutput =
        serde_json::from_str(&output_str).context("Failed to parse ffprobe output")?;

    let duration = probe
        .format
        .and_then(|f| f.duration)
        .and_then(|d| d.parse::<f64>().ok())
        .unwrap_or(0.0);

    let streams = probe.streams.unwrap_or_default();

    let video_codec = streams
        .iter()
        .find(|s| s.codec_type == "video")
        .and_then(|s| s.codec_name.clone())
        .unwrap_or_else(|| "unknown".to_string());

    let mut audio_tracks = Vec::new();
    let mut audio_idx_counter = 0;

    for stream in &streams {
        if stream.codec_type == "audio" {
            let lang = stream.tags.as_ref().and_then(|t| t.language.clone());
            let label = stream
                .tags
                .as_ref()
                .and_then(|t| t.title.clone().or_else(|| t.label.clone()));

            audio_tracks.push(AudioTrack {
                index: audio_idx_counter,
                language: lang,
                label: label,
                codec: stream
                    .codec_name
                    .clone()
                    .unwrap_or_else(|| "unknown".to_string()),
                channels: stream.channels,
            });
            audio_idx_counter += 1;
        }
    }

    let mut subtitle_tracks = Vec::new();
    let mut subtitle_idx_counter = 0;

    for stream in &streams {
        if stream.codec_type == "subtitle" {
            let lang = stream.tags.as_ref().and_then(|t| t.language.clone());
            let label = stream
                .tags
                .as_ref()
                .and_then(|t| t.title.clone().or_else(|| t.label.clone()));

            // Some codecs might be image based (hdmv_pgs_subtitle, dvd_subtitle) which ffmpeg might struggle to convert to webvtt nicely without excessive CPU or OCR.
            // TEXT based subtitles (subrip, mov_text, webvtt) convert easily.
            // For now, we list them all, but extraction might fail for bitmap subs.

            subtitle_tracks.push(SubtitleTrack {
                index: subtitle_idx_counter,
                language: lang,
                label: label,
                codec: stream
                    .codec_name
                    .clone()
                    .unwrap_or_else(|| "unknown".to_string()),
            });
            subtitle_idx_counter += 1;
        }
    }

    Ok(MovieMetadata {
        duration,
        video_codec,
        audio_tracks,
        subtitle_tracks,
    })
}
