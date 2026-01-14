use anyhow::{Context, Result};
use serde::Serialize;
use serde_json::Value;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::thread;

pub struct Transcoder {
    input_path: std::path::PathBuf,
}

#[derive(Serialize, Debug, Clone)]
pub struct SubtitleInfo {
    pub index: usize,
    pub language: Option<String>,
    pub title: Option<String>,
}

#[derive(Serialize, Debug)]
pub struct MediaInfo {
    pub container: String,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
    pub duration: Option<f64>,
    pub subtitles: Vec<SubtitleInfo>,
}

impl Transcoder {
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self {
            input_path: path.as_ref().to_path_buf(),
        }
    }

    /// Spawns the transcoding process using ffmpeg CLI for robustness.
    pub fn stream(&self, start_pos: Option<f64>) -> Result<Receiver<Vec<u8>>> {
        let (tx, rx) = channel();
        let path = self.input_path.clone();

        if !path.exists() {
            return Err(anyhow::anyhow!("File not found"));
        }

        // Get metadata to decide transcoding strategy
        let info = self.get_metadata()?;

        thread::spawn(move || {
            if let Err(e) = run_transcode_cli(path, tx, start_pos, info) {
                eprintln!("Transcoding error: {:?}", e);
            }
        });

        Ok(rx)
    }

    /// Probes the file metadata using ffprobe
    pub fn get_metadata(&self) -> Result<MediaInfo> {
        let output = Command::new("ffprobe")
            .args(&[
                "-v",
                "quiet",
                "-print_format",
                "json",
                "-show_format",
                "-show_streams",
            ])
            .arg(&self.input_path)
            .output()
            .context("Failed to run ffprobe")?;

        if !output.status.success() {
            return Err(anyhow::anyhow!("ffprobe failed"));
        }

        let json: Value = serde_json::from_slice(&output.stdout)?;

        // Extract basic info
        let container = json["format"]["format_name"]
            .as_str()
            .unwrap_or("unknown")
            .to_string();

        let duration = json["format"]["duration"]
            .as_str()
            .and_then(|s| s.parse::<f64>().ok());

        let streams = json["streams"]
            .as_array()
            .ok_or(anyhow::anyhow!("No streams found"))?;

        let mut video_codec = None;
        let mut audio_codec = None;
        let mut subtitles = Vec::new();

        for (i, stream) in streams.iter().enumerate() {
            let codec_type = stream["codec_type"].as_str().unwrap_or("");
            let codec_name = stream["codec_name"].as_str().map(|s| s.to_string());

            match codec_type {
                "video" if video_codec.is_none() => video_codec = codec_name,
                "audio" if audio_codec.is_none() => audio_codec = codec_name,
                "subtitle" => {
                    let title = stream["tags"]["title"].as_str().map(|s| s.to_string());
                    let language = stream["tags"]["language"].as_str().map(|s| s.to_string());
                    subtitles.push(SubtitleInfo {
                        index: i,
                        language,
                        title,
                    });
                }
                _ => {}
            }
        }

        Ok(MediaInfo {
            container,
            video_codec,
            audio_codec,
            duration,
            subtitles,
        })
    }

    /// Extracts a specific subtitle stream and converts it to WebVTT
    pub fn subtitles(&self, index: usize) -> Result<Receiver<Vec<u8>>> {
        let (tx, rx) = channel();
        let path = self.input_path.clone();

        if !path.exists() {
            return Err(anyhow::anyhow!("File not found"));
        }

        thread::spawn(move || {
            let child = Command::new("ffmpeg")
                .args(&[
                    "-v",
                    "quiet",
                    "-i",
                    &path.to_string_lossy(),
                    "-map",
                    &format!("0:{}", index),
                    "-f",
                    "webvtt",
                    "pipe:1",
                ])
                .stdout(Stdio::piped())
                .stderr(Stdio::null()) // Don't care about stderr for subs
                .spawn();

            if let Ok(mut c) = child {
                if let Some(mut stdout) = c.stdout.take() {
                    let mut buffer = [0u8; 1024];
                    while let Ok(n) = stdout.read(&mut buffer) {
                        if n == 0 {
                            break;
                        }
                        if tx.send(buffer[..n].to_vec()).is_err() {
                            let _ = c.kill();
                            break;
                        }
                    }
                }
                let _ = c.wait();
            }
        });

        Ok(rx)
    }
}

fn run_transcode_cli(
    path: std::path::PathBuf,
    tx: Sender<Vec<u8>>,
    start_time: Option<f64>,
    info: MediaInfo,
) -> Result<()> {
    let mut args = Vec::new();

    if let Some(t) = start_time {
        args.push("-ss".to_string());
        args.push(format!("{:.4}", t));
    }

    args.push("-i".to_string());
    args.push(path.to_string_lossy().to_string());

    // --- Smart Transcoding Logic ---
    let v_codec = info.video_codec.as_deref().unwrap_or("");
    let a_codec = info.audio_codec.as_deref().unwrap_or("");
    let container = info.container.to_lowercase();

    // 1. Video Decision
    // Browsers natively support h264/avc1 in MP4.
    // Many also support HEVC/h265 now (especially on Mac/Safari).
    // Also, AVI container is problematic for web, so we force transcode if it's AVI.
    let needs_v_transcode =
        !(v_codec == "h264" || v_codec == "hevc" || v_codec == "h265") || container.contains("avi");

    if needs_v_transcode {
        println!("Re-encoding video: {} -> h264", v_codec);
        // Use hardware acceleration if on Mac (Toolbox)
        #[cfg(target_os = "macos")]
        {
            args.push("-c:v".to_string());
            args.push("h264_videotoolbox".to_string());
            args.push("-b:v".to_string());
            args.push("5M".to_string());
            args.push("-allow_sw".to_string());
            args.push("1".to_string());
        }
        #[cfg(not(target_os = "macos"))]
        {
            args.push("-c:v".to_string());
            args.push("libx264".to_string());
            args.push("-preset".to_string());
            args.push("ultrafast".to_string());
            args.push("-crf".to_string());
            args.push("23".to_string());
        }
    } else {
        println!("Copying video stream: {}", v_codec);
        args.push("-c:v".to_string());
        args.push("copy".to_string());
    }

    // 2. Audio Decision
    // Browsers like aac or mp3. We'll stick to aac for better compatibility.
    let needs_a_transcode = a_codec != "aac";

    if needs_a_transcode {
        println!("Re-encoding audio: {} -> aac", a_codec);
        args.push("-c:a".to_string());
        args.push("aac".to_string());
        args.push("-b:a".to_string());
        args.push("128k".to_string());
    } else {
        println!("Copying audio stream: {}", a_codec);
        args.push("-c:a".to_string());
        args.push("copy".to_string());
    }

    // Output settings
    args.push("-f".to_string());
    args.push("mp4".to_string());
    args.push("-movflags".to_string());
    args.push("frag_keyframe+empty_moov+default_base_moof".to_string());

    args.push("pipe:1".to_string());

    println!("Starting ffmpeg with args: {:?}", args);

    let mut child = Command::new("ffmpeg")
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("Failed to spawn ffmpeg")?;

    let mut stdout = child
        .stdout
        .take()
        .ok_or(anyhow::anyhow!("Failed to open stdout"))?;

    let mut buffer = [0u8; 4096];

    loop {
        match stdout.read(&mut buffer) {
            Ok(0) => break, // EOF
            Ok(n) => {
                if tx.send(buffer[..n].to_vec()).is_err() {
                    let _ = child.kill();
                    break;
                }
            }
            Err(_) => {
                let _ = child.kill();
                break;
            }
        }
    }

    let _ = child.wait();

    Ok(())
}
