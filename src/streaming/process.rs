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

// --- Keyframe Probe ---

#[derive(Deserialize)]
struct FFProbeFrame {
    pkt_pts_time: String,
}

#[derive(Deserialize)]
struct FFProbeFrameOutput {
    frames: Option<Vec<FFProbeFrame>>,
}

pub async fn find_keyframe(path: &Path, target: f64) -> Result<f64> {
    if target <= 0.0 {
        return Ok(0.0);
    }

    // Search window: Look back 60s. ffmpeg -ss (target-60) snaps to a keyframe before that.
    // Then we read frames forward.
    let search_start = (target - 60.0).max(0.0);

    println!(
        "[keyframe] Probing keyframe near {} (scanning from {})",
        target, search_start
    );

    // Command: ffprobe -ss {search_start} -i {path} -select_streams v -skip_frame nokey -show_entries frame=pkt_pts_time -of json -read_intervals "%+70"
    // Note: -read_intervals is relative to the seek point if we use input seeking? No, it's absolute timestamps usually.
    // simpler: just scan 70s of duration.

    // We can use `-read_intervals` with `+duration` syntax relative to input?
    // Or just let it run and pipe output? process.kill() isn't easy here.
    // Best to use -read_intervals with absolute times if possible, or relative.

    // Let's try explicit absolute time scan range.
    // But we need input seeking for speed.
    // If we use input seeking `-ss`, timestamps are reset? or processed?
    // ffprobe usually reports preserved timestamps if we don't transcode?
    // Let's verify: `ffprobe -ss 10 -i file -show_entries frame=pkt_pts_time`.
    // It reports timestamps relative to 0 usually? No, pkt_pts_time is usually absolute or relative to file.

    // SAFEST: No input seeking, just read_intervals.
    // But read_intervals failed last time.
    // Maybe `pkt_pts_time` was missing?

    // Let's use `frame=best_effort_timestamp_time,pkt_pts_time`.

    let start_scan = (target - 60.0).max(0.0);
    let end_scan = target + 5.0; // slightly past target
    let interval = format!("{}%{}", start_scan, end_scan);

    let output = tokio::process::Command::new("ffprobe")
        .args(&[
            "-v",
            "error",
            "-select_streams",
            "v",
            "-skip_frame",
            "nokey",
            "-show_entries",
            "frame=pkt_pts_time",
            "-of",
            "json",
            "-read_intervals",
            &interval,
        ])
        .arg(path)
        .output()
        .await
        .context("Failed to run ffprobe")?;

    if !output.status.success() {
        return Err(anyhow::anyhow!("ffprobe failed"));
    }

    let output_str = String::from_utf8_lossy(&output.stdout);
    let result: FFProbeFrameOutput = serde_json::from_str(&output_str)?;

    if let Some(frames) = result.frames {
        // Find last keyframe <= target
        // Add a small epsilon 0.1 to include target if it is exactly a keyframe
        let mut candidate = 0.0;
        let mut found = false;

        for frame in frames {
            let ts = frame.pkt_pts_time.parse::<f64>().unwrap_or(-1.0);
            if ts >= 0.0 && ts <= target + 0.1 {
                candidate = ts;
                found = true;
            }
        }

        if found {
            println!("[keyframe] Found keyframe at {}", candidate);
            return Ok(candidate);
        }
    }

    println!("[keyframe] No keyframe found, defaulting to target.");
    Ok(target)
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
    tags: Option<FFProbeTags>,
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
        .as_ref()
        .and_then(|f| f.duration.as_ref())
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

    let title = probe.format.and_then(|f| f.tags).and_then(|t| t.title);

    Ok(MovieMetadata {
        duration,
        video_codec,
        title,
        audio_tracks,
        subtitle_tracks,
    })
}
