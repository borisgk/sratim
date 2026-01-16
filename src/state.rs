use std::path::PathBuf;

#[derive(Clone)]
pub struct AppState {
    pub movies_dir: PathBuf,
}
