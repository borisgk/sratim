use tokio::fs::OpenOptions;
use tokio::io::AsyncWriteExt;
use chrono::Local;

pub async fn log_event(message: &str) {
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .open("activity.log")
        .await
    {
        let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let log_line = format!("[{}] {}\n", timestamp, message);
        let _ = file.write_all(log_line.as_bytes()).await;
    }
}
