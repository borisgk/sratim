use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::task::AbortHandle;

#[derive(Clone)]
pub struct AppState {
    pub movies_dir: PathBuf,
    pub transcode_manager: Arc<TranscodeManager>,
}

#[derive(Hash, PartialEq, Eq, Clone, Debug)]
pub enum TaskKey {
    Stream(PathBuf),
    Subtitles(PathBuf, usize),
}

pub struct TranscodeManager {
    tasks: Mutex<HashMap<TaskKey, AbortHandle>>,
}

impl TranscodeManager {
    pub fn new() -> Self {
        Self {
            tasks: Mutex::new(HashMap::new()),
        }
    }

    pub fn register(&self, key: TaskKey, handle: AbortHandle) {
        let mut tasks = self.tasks.lock().unwrap();
        if let Some(old) = tasks.insert(key.clone(), handle) {
            println!("[manager] Aborting previous task for {:?}", key);
            old.abort();
        }
    }

    pub fn unregister(&self, key: &TaskKey) {
        let mut tasks = self.tasks.lock().unwrap();
        tasks.remove(key);
    }
}
