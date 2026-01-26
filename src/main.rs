use axum::{
    Router,
    http::{HeaderValue, header},
    routing::get,
};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::sync::Mutex;
use tower::ServiceBuilder;
use tower_http::{cors::CorsLayer, services::ServeDir, set_header::SetResponseHeaderLayer};

use sratim::models::{AppConfig, AppState};
use sratim::routes::video;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let config = AppConfig::load().expect("Failed to load configuration");

    let movies_dir = config.movies_dir.clone();
    if !movies_dir.exists() {
        std::fs::create_dir_all(&movies_dir).expect("Failed to create movies directory");
    }

    let dash_temp_dir = std::env::temp_dir().join("sratim_dash");
    std::fs::create_dir_all(&dash_temp_dir).expect("Failed to create dash temp directory");

    let auth_state = sratim::auth::AuthState::new().await;

    let shared_state = AppState {
        movies_dir: movies_dir.clone(),
        dash_temp_dir,
        ffmpeg_process: Arc::new(Mutex::new(None)),
        auth: auth_state,
    };

    let protected_routes = Router::new()
        .route("/api/movies", get(video::list_files))
        .route("/api/metadata", get(video::get_metadata))
        .route("/api/stream", get(video::stream_video))
        .route("/api/subtitles", get(video::get_subtitles))
        .route("/api/lookup", get(video::lookup_metadata))
        .route("/api/me", get(sratim::auth::me_handler))
        .nest_service("/content", ServeDir::new(&movies_dir))
        .layer(axum::middleware::from_fn(sratim::auth::auth_middleware));

    let app = Router::new()
        .merge(protected_routes)
        .route(
            "/api/login",
            axum::routing::post(sratim::auth::login_handler),
        )
        .route(
            "/api/logout",
            axum::routing::post(sratim::auth::logout_handler),
        )
        .fallback_service(
            ServiceBuilder::new()
                .layer(SetResponseHeaderLayer::overriding(
                    header::CACHE_CONTROL,
                    HeaderValue::from_static(
                        "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
                    ),
                ))
                .service(ServeDir::new(&config.frontend_dir)),
        )
        .layer(CorsLayer::permissive())
        .with_state(shared_state);

    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid host/port");

    println!("Server running on http://{}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
