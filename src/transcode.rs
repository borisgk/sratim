use anyhow::{Context, Result};
use bytes::Bytes;
use futures_core::Stream;
use serde::Serialize;
use serde_json::Value;

use std::path::Path;
use std::pin::Pin;
use std::process::Stdio;
use std::task::{Context as TaskContext, Poll};

use tokio::process::{ChildStdout, Command};
use tokio_util::io::ReaderStream;

/// A wrapper around tokio::process::Child that ensures the entire process tree
/// is killed when dropped, using a specific Session ID tag.
struct ScopedChild {
    id: u32, // PID (still useful for initial kill)
    child: Option<tokio::process::Child>,
    session_id: String,
}

impl ScopedChild {
    fn new(child: tokio::process::Child, session_id: String) -> Self {
        let id = child.id().expect("Child must have a PID");
        Self {
            id,
            child: Some(child),
            session_id,
        }
    }
}

impl Drop for ScopedChild {
    fn drop(&mut self) {
        let id = self.id;
        let session_id = self.session_id.clone();

        println!("[process] Drop: Stopping session {}", session_id);

        // 1. Kill the direct PID immediately (Fastest reaction)
        unsafe {
            libc::kill(-(id as i32), libc::SIGKILL);
        }

        // 2. Spawn a background task to SWEEP via Session ID
        // This catches wrappers, grandchildren, and detached processes.
        if let Some(mut child) = self.child.take() {
            if let Ok(handle) = tokio::runtime::Handle::try_current() {
                handle.spawn(async move {
                    println!(
                        "[cleanup] Sweeping session {}. Scanning process list...",
                        session_id
                    );

                    // Run pgrep -f sratim_id=<UUID>
                    let pgrep = tokio::process::Command::new("pgrep")
                        .arg("-a") // Show full command line for logging
                        .arg("-f") // Match against full command line
                        .arg(format!("sratim_id={}", session_id))
                        .output()
                        .await;

                    match pgrep {
                        Ok(output) if output.status.success() => {
                            let stdout = String::from_utf8_lossy(&output.stdout);
                            for line in stdout.lines() {
                                if !line.trim().is_empty() {
                                    // Line: "PID COMMAND"
                                    if let Some(pid_str) = line.split_whitespace().next() {
                                        if let Ok(pid) = pid_str.parse::<i32>() {
                                            println!(
                                                "[cleanup] KILLING leaked process: {} (PID: {})",
                                                line, pid
                                            );
                                            unsafe {
                                                libc::kill(pid, libc::SIGKILL);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        _ => {} // No matches found (good!)
                    }

                    // 3. Reap the original zombie
                    match child.wait().await {
                        Ok(_) => {
                            // println!("[reaper] Parent process {} exited: {}", id, status)
                        }
                        Err(e) => eprintln!("[reaper] Failed to reap parent {}: {}", id, e),
                    }
                });
            } else {
                eprintln!(
                    "[process] Warning: Dropped without Tokio context. Session {} might leak.",
                    session_id
                );
            }
        }
    }
}

/// A stream that owns the ffmpeg process. When this stream is dropped,
/// the `ScopedChild` is dropped, triggering a SIGKILL on the process group.
pub struct FfmpegStream {
    stream: ReaderStream<ChildStdout>,
    // We hold this to ensure it drops when the stream drops
    _process: ScopedChild,
}

impl FfmpegStream {
    pub fn session_id(&self) -> &str {
        &self._process.session_id
    }
}

impl Stream for FfmpegStream {
    type Item = std::io::Result<Bytes>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<Option<Self::Item>> {
        Pin::new(&mut self.stream).poll_next(cx)
    }
}

pub struct Transcoder {
    input_path: std::path::PathBuf,
}

#[derive(Serialize, Debug, Clone)]
pub struct AudioTrackInfo {
    pub index: usize,
    pub language: Option<String>,
    pub title: Option<String>,
    pub codec: String,
    pub channels: Option<i32>,
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
    pub audio_tracks: Vec<AudioTrackInfo>,
    pub duration: Option<f64>,
    pub subtitles: Vec<SubtitleInfo>,
}

impl Transcoder {
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self {
            input_path: path.as_ref().to_path_buf(),
        }
    }

    /// Spawns the transcoding process and returns a Stream that owns the child process.
    pub async fn stream(
        &self,
        start_pos: Option<f64>,
        audio_stream_index: Option<usize>,
    ) -> Result<FfmpegStream> {
        let path = self.input_path.clone();

        if !path.exists() {
            return Err(anyhow::anyhow!("File not found"));
        }

        // Get metadata to decide transcoding strategy
        let info = self.get_metadata().await?;

        // Generate a unique session ID for this transcode
        let session_id = uuid::Uuid::new_v4().to_string();

        let (child, stdout, stderr) = prepare_transcode_child(
            path.clone(),
            start_pos,
            audio_stream_index,
            info,
            &session_id,
        )?;

        // Spawn a thread to read stderr (detached, harmless)
        tokio::spawn(async move {
            use tokio::io::AsyncBufReadExt;
            let reader = tokio::io::BufReader::new(stderr);
            let mut lines = reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if !line.starts_with("frame=") {
                    eprintln!("[ffmpeg] {}", line);
                }
            }
        });

        Ok(FfmpegStream {
            stream: ReaderStream::new(stdout),
            _process: ScopedChild::new(child, session_id),
        })
    }

    /// Probes the file metadata using ffprobe
    pub async fn get_metadata(&self) -> Result<MediaInfo> {
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
            .kill_on_drop(true)
            .output()
            .await
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
        let mut audio_tracks = Vec::new();
        let mut subtitles = Vec::new();

        for (i, stream) in streams.iter().enumerate() {
            let codec_type = stream["codec_type"].as_str().unwrap_or("");
            let codec_name = stream["codec_name"].as_str().map(|s| s.to_string());

            match codec_type {
                "video" if video_codec.is_none() => video_codec = codec_name,
                "audio" => {
                    if audio_codec.is_none() {
                        audio_codec = codec_name.clone();
                    }
                    let title = stream["tags"]["title"].as_str().map(|s| s.to_string());
                    let language = stream["tags"]["language"].as_str().map(|s| s.to_string());
                    let channels = stream["channels"].as_i64().map(|c| c as i32);

                    audio_tracks.push(AudioTrackInfo {
                        index: i,
                        language,
                        title,
                        codec: codec_name.unwrap_or_default(),
                        channels,
                    });
                }
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
            audio_tracks,
            duration,
            subtitles,
        })
    }

    /// Extracts a specific subtitle stream and converts it to WebVTT
    /// For subtitles, we can stick to the simple one-shot or apply the same stream logic.
    /// Since subs are small, the current simple implementation is likely fine, but to be safe
    /// let's switch it to Direct Stream as well.
    pub async fn subtitles(&self, index: usize) -> Result<FfmpegStream> {
        let path = self.input_path.clone();

        if !path.exists() {
            return Err(anyhow::anyhow!("File not found"));
        }

        // Generate unique session ID for subtitles
        let session_id = uuid::Uuid::new_v4().to_string();

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
                "-metadata",
                &format!("sratim_id={}", session_id),
                "pipe:1",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0) // New process group
            .spawn()
            .context("Failed to spawn ffmpeg")?;

        let mut scoped_child = ScopedChild::new(child, session_id);
        let stdout = scoped_child
            .child
            .as_mut()
            .unwrap()
            .stdout
            .take()
            .expect("Failed to open stdout");
        // No stderr needed for subs

        Ok(FfmpegStream {
            stream: ReaderStream::new(stdout),
            _process: scoped_child,
        })
    }
}

fn prepare_transcode_child(
    path: std::path::PathBuf,
    start_time: Option<f64>,
    audio_stream_index: Option<usize>,
    info: MediaInfo,
    session_id: &str,
) -> Result<(
    tokio::process::Child,
    ChildStdout,
    tokio::process::ChildStderr,
)> {
    let mut args = Vec::new();

    // Global inputs flags
    args.push("-analyzeduration".to_string());
    args.push("10M".to_string());
    args.push("-probesize".to_string());
    args.push("10M".to_string());
    args.push("-fflags".to_string());
    args.push("+genpts".to_string());

    let mut accurate_ss: Option<f64> = None;

    if let Some(t) = start_time {
        let duration = info.duration.unwrap_or(0.0);
        println!("=== SEEK INFO ===");
        println!("File duration: {:.2}s", duration);
        println!("Target seek: {:.2}s", t);

        // Split seek
        let f = (t - 30.0).max(0.0);
        let a = t - f;

        accurate_ss = Some(a);

        args.push("-ss".to_string());
        args.push(format!("{:.4}", f));
    }

    args.push("-i".to_string());
    args.push(path.to_string_lossy().to_string());

    if let Some(a) = accurate_ss {
        args.push("-ss".to_string());
        args.push(format!("{:.4}", a));

        let duration = info.duration.unwrap_or(0.0);
        let t_target = start_time.unwrap_or(0.0);
        if duration > 0.0 && t_target < duration {
            let remaining = duration - t_target;
            args.push("-t".to_string());
            args.push(format!("{:.2}", remaining));
        }
    }

    args.push("-map".to_string());
    args.push("0:v:0".to_string());

    args.push("-map".to_string());
    if let Some(idx) = audio_stream_index {
        args.push(format!("0:{}", idx));
    } else {
        args.push("0:a:0".to_string());
    }

    args.push("-fps_mode".to_string());
    args.push("passthrough".to_string());
    args.push("-max_muxing_queue_size".to_string());
    args.push("4096".to_string());

    // --- Smart Transcoding Logic ---
    let v_codec = info.video_codec.as_deref().unwrap_or("");
    let mut a_codec = info.audio_codec.as_deref().unwrap_or("");
    if let Some(idx) = audio_stream_index {
        if let Some(track) = info.audio_tracks.iter().find(|t| t.index == idx) {
            a_codec = &track.codec;
        }
    }

    let container = info.container.to_lowercase();
    let needs_v_transcode =
        !(v_codec == "h264" || v_codec == "hevc" || v_codec == "h265") || container.contains("avi");

    if needs_v_transcode {
        println!("Re-encoding video: {} -> h264", v_codec);
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

    let needs_a_transcode = a_codec != "aac";

    if needs_a_transcode {
        println!("Re-encoding audio: {} -> aac", a_codec);
        args.push("-c:a".to_string());
        args.push("aac".to_string());
        args.push("-b:a".to_string());
        args.push("128k".to_string());
        args.push("-async".to_string());
        args.push("1".to_string());
    } else {
        println!("Copying audio stream: {}", a_codec);
        args.push("-c:a".to_string());
        args.push("copy".to_string());
    }

    args.push("-f".to_string());
    args.push("mp4".to_string());
    args.push("-movflags".to_string());
    args.push("frag_keyframe+empty_moov+default_base_moof".to_string());

    args.push("pipe:1".to_string());

    args.push("-metadata".to_string());
    args.push(format!("sratim_id={}", session_id));

    println!(
        "Starting ffmpeg session [{}] with args: {:?}",
        session_id, args
    );

    let mut command = Command::new("ffmpeg");
    command.args(&args);
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    command.process_group(0); // setpgid(0, 0) -> New process group leader

    #[cfg(target_os = "linux")]
    unsafe {
        command.pre_exec(|| {
            // PR_SET_PDEATHSIG = 1
            // Ensure child dies if we die
            let r = libc::prctl(1, libc::SIGKILL, 0, 0, 0);
            if r != 0 {
                // Ignore error, best effort
            }
            Ok(())
        });
    }

    let mut child = command.spawn().context("Failed to spawn ffmpeg")?;

    if let Some(id) = child.id() {
        println!(
            "[process] Spawned ffmpeg parent {} for session {}",
            id, session_id
        );
    }

    let stdout = child
        .stdout
        .take()
        .ok_or(anyhow::anyhow!("Failed to open stdout"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or(anyhow::anyhow!("Failed to open stderr"))?;

    Ok((child, stdout, stderr))
}
