use serde::{Deserialize, Serialize};

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum MediaNode {
    Folder { name: String, path: String },
    File { name: String, path: String },
}

#[derive(Deserialize)]
pub struct ListParams {
    pub path: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscodeParams {
    pub path: String,
    pub start: Option<f64>,
    pub audio_track: Option<usize>,
}

#[derive(Deserialize)]
pub struct SubtitleParams {
    pub path: String,
    pub index: usize,
}
