use axum::{
    Router,
    http::{HeaderValue, header},
    routing::get,
};
use std::net::SocketAddr;
use std::sync::Arc;
use tower::ServiceBuilder;
use tower_http::{cors::CorsLayer, services::ServeDir, set_header::SetResponseHeaderLayer};

mod config;
mod handlers;
mod models;
mod state;
mod transcode;

use config::AppConfig;
use state::{AppState, TranscodeManager};

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::fmt::init();

    // Load configuration
    let config = AppConfig::load().expect("Failed to load configuration");

    let movies_dir = config.movies_dir.clone();
    if !movies_dir.exists() {
        std::fs::create_dir_all(&movies_dir).expect("Failed to create movies directory");
        println!("Created movies directory: {:?}", movies_dir);
    }

    let shared_state = Arc::new(AppState {
        movies_dir: movies_dir.clone(),
        transcode_manager: Arc::new(TranscodeManager::new()),
    });

    // Router
    let app = Router::new()
        .route("/api/movies", get(handlers::list_movies))
        // Serve the movies directory directly so browsers can request ranges
        .nest_service("/content", ServeDir::new(&movies_dir))
        .route("/api/transcode", get(handlers::transcode_movie))
        .route("/api/metadata", get(handlers::get_metadata))
        .route("/api/subtitles", get(handlers::extract_subtitles))
        // Serve the frontend with cache-disabling headers
        .fallback_service(
            ServiceBuilder::new()
                .layer(SetResponseHeaderLayer::overriding(
                    header::CACHE_CONTROL,
                    HeaderValue::from_static(
                        "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
                    ),
                ))
                .layer(SetResponseHeaderLayer::overriding(
                    header::PRAGMA,
                    HeaderValue::from_static("no-cache"),
                ))
                .layer(SetResponseHeaderLayer::overriding(
                    header::EXPIRES,
                    HeaderValue::from_static("0"),
                ))
                .service(ServeDir::new(&config.frontend_dir)),
        )
        .layer(CorsLayer::permissive())
        .with_state(shared_state);

    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid host/port in configuration");

    println!("Server running on http://{}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
