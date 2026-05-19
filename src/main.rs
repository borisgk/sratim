use axum::{
    Router,
    extract::State,
    response::IntoResponse,
    routing::get,
};
use std::net::SocketAddr;
use std::sync::Arc;
use tower_http::cors::CorsLayer;

use sratim::models::{AppConfig, AppState};
use sratim::routes::video;

async fn debug_hash_handler(axum::extract::Path(password): axum::extract::Path<String>) -> String {
    bcrypt::hash(password, bcrypt::DEFAULT_COST).unwrap()
}

async fn fallback_handler(
    uri: axum::http::Uri,
    State(state): State<AppState>,
) -> impl IntoResponse {
    let mut path_str = uri.path().trim_start_matches('/').to_string();
    if path_str.is_empty() {
        path_str = "index.html".to_string();
    }

    // 1. Try to serve from local filesystem if the folder exists and is a file
    let local_path = state.config.frontend_dir.join(&path_str);
    if local_path.is_file() {
        if let Ok(content) = tokio::fs::read(&local_path).await {
            let mime = mime_guess::from_path(&local_path).first_or_octet_stream();
            return (
                axum::http::StatusCode::OK,
                [
                    (axum::http::header::CONTENT_TYPE, mime.as_ref()),
                    (
                        axum::http::header::CACHE_CONTROL,
                        "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
                    ),
                ],
                content,
            )
                .into_response();
        }
    }

    // 2. Try to serve from embedded assets
    if let Some(embedded_file) = sratim::assets::Assets::get(&path_str) {
        let mime = mime_guess::from_path(&path_str).first_or_octet_stream();
        return (
            axum::http::StatusCode::OK,
            [
                (axum::http::header::CONTENT_TYPE, mime.as_ref()),
                (
                    axum::http::header::CACHE_CONTROL,
                    "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
                ),
            ],
            embedded_file.data.into_owned(),
        )
            .into_response();
    }

    // 3. Fallback to 404 Not Found
    (
        axum::http::StatusCode::NOT_FOUND,
        [
            (
                axum::http::header::CACHE_CONTROL,
                "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0",
            ),
        ],
        "Not Found",
    )
        .into_response()
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let config = AppConfig::load().expect("Failed to load configuration");

    // Ensure data directory exists
    if !config.data_dir.exists() {
        tokio::fs::create_dir_all(&config.data_dir)
            .await
            .expect("Failed to create data directory");
    }

    let auth_state = sratim::auth::AuthState::new(config.data_dir.clone()).await;

    // Load libraries
    let libraries_file = config.data_dir.join("libraries.json");
    let libraries = if let Ok(content) = tokio::fs::read_to_string(&libraries_file).await {
        serde_json::from_str::<Vec<sratim::models::Library>>(&content).unwrap_or_default()
    } else {
        Vec::new()
    };

    // --- Database ---
    let db_path = config.data_dir.join("metadata.db");
    let db = sratim::db::DbClient::init(db_path)
        .await
        .expect("Failed to initialize database");
    let db = Arc::new(db);

    // --- Background Scanner ---
    let (scanner, _worker_handle) = sratim::scanner::Scanner::new(config.clone(), db.clone());
    let scanner = Arc::new(scanner);

    let shared_state = AppState {
        auth: auth_state,
        libraries: Arc::new(tokio::sync::RwLock::new(libraries)),
        config: config.clone(),
        scanner: scanner.clone(),
        db: db.clone(),
    };

    // Initial Scan
    {
        let libraries = shared_state.libraries.read().await;
        for lib in libraries.iter() {
            if lib.kind == sratim::models::LibraryType::Movies
                || lib.kind == sratim::models::LibraryType::TVShows
            {
                let scanner_ref = scanner.clone();
                let lib_clone = lib.clone();
                tokio::spawn(async move {
                    scanner_ref.scan_library(&lib_clone).await;
                });
            }
        }
    }

    let protected_routes = Router::new()
        .route("/api/movies", get(video::list_files))
        .route("/api/metadata", get(video::get_metadata))
        .route("/api/stream", get(video::stream_video))
        .route("/api/subtitles", get(video::get_subtitles))
        .route("/api/lookup", get(video::lookup_metadata))
        .route(
            "/api/rescan",
            axum::routing::post(sratim::routes::library::rescan_libraries),
        )
        .route("/api/me", get(sratim::auth::me_handler))
        .route(
            "/api/change-password",
            axum::routing::post(sratim::auth::change_password_handler),
        )
        // Library Routes
        // User Management Routes
        .route(
            "/api/users",
            get(sratim::auth::list_users_handler).post(sratim::auth::create_user_handler),
        )
        .route(
            "/api/users/:username",
            axum::routing::delete(sratim::auth::delete_user_handler),
        )
        .route(
            "/api/users/:username/password",
            axum::routing::put(sratim::auth::admin_change_password_handler),
        )
        .route(
            "/api/libraries",
            get(sratim::routes::library::get_libraries)
                .post(sratim::routes::library::create_library),
        )
        .route(
            "/api/libraries/:id",
            axum::routing::delete(sratim::routes::library::delete_library)
                .put(sratim::routes::library::update_library),
        )
        .route(
            "/api/libraries/:id/content/*path",
            get(sratim::routes::library::serve_content),
        )
        .route(
            "/api/fs/browse",
            get(sratim::routes::library::browse_filesystem),
        )
        .layer(axum::middleware::from_fn_with_state(
            shared_state.clone(),
            sratim::auth::auth_middleware,
        ));

    let app = Router::new()
        .merge(protected_routes)
        .route("/api/debug/hash/:password", get(debug_hash_handler))
        .route("/", get(sratim::routes::ui::index_handler))
        .route(
            "/share",
            axum::routing::get(sratim::routes::ui::share_handler),
        )
        .route(
            "/watch",
            axum::routing::post(sratim::routes::ui::watch_handler),
        )
        .route(
            "/api/login",
            axum::routing::post(sratim::auth::login_handler),
        )
        .route(
            "/api/logout",
            axum::routing::post(sratim::auth::logout_handler),
        )
        .fallback(fallback_handler)
        .layer(CorsLayer::permissive())
        .with_state(shared_state);

    let addr: SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .expect("Invalid host/port");

    println!("Server running on http://{}", addr);
    let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await.unwrap();
}
