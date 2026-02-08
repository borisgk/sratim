use axum::{
    debug_handler,
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Redirect, Response},
};
use axum_extra::extract::cookie::CookieJar;
use jsonwebtoken::{DecodingKey, Validation, decode};
use serde::Deserialize;

use crate::{
    auth::{COOKIE_NAME, Claims, JWT_SECRET},
    models::AppState,
    routes::video::get_base_path,
};
use askama::Template;

#[derive(Template)]
#[template(path = "index.html")]
pub struct IndexTemplate {
    pub username: String,
    pub is_admin: bool,
    pub is_admin_str: String,
    pub mode: String, // "libraries" or "files"
    pub libraries: Vec<LibraryView>,
    pub files: Vec<FileView>,
    pub breadcrumbs: Vec<Breadcrumb>,
    pub library_id: Option<String>,
    pub parent_link: Option<String>,
}

impl IntoResponse for IndexTemplate {
    fn into_response(self) -> Response {
        match self.render() {
            Ok(html) => axum::response::Html(html).into_response(),
            Err(err) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to render template: {}", err),
            )
                .into_response(),
        }
    }
}

pub struct LibraryView {
    pub id: String,
    pub name: String,
    pub image: String,
}

pub struct FileView {
    pub name: String,
    pub display_name: String,
    pub path_encoded: String,
    pub is_dir: bool,
    pub poster_url: Option<String>,
}

pub struct Breadcrumb {
    pub name: String,
    pub library_id: String,
    pub path: String,
}

#[derive(Deserialize)]
pub struct IndexParams {
    pub library_id: Option<String>,
    pub path: Option<String>,
}

#[debug_handler]
pub async fn index_handler(
    State(state): State<AppState>,
    jar: CookieJar,
    Query(params): Query<IndexParams>,
) -> Response {
    // 1. Check Auth (Cookie)
    let user_data = if let Some(token) = jar.get(COOKIE_NAME) {
        let validation = Validation::default();
        if let Ok(data) = decode::<Claims>(
            token.value(),
            &DecodingKey::from_secret(JWT_SECRET),
            &validation,
        ) {
            data.claims
        } else {
            return Redirect::to("/login.html").into_response();
        }
    } else {
        return Redirect::to("/login.html").into_response();
    };

    let username = user_data.sub;
    let is_admin = user_data.is_admin;
    let is_admin_str = if is_admin {
        "(Admin)".to_string()
    } else {
        "".to_string()
    };

    // 2. Determine Mode
    if let Some(lib_id) = &params.library_id {
        // Files Mode
        let path = params.path.clone().unwrap_or_default();

        // Fetch files using existing logic?
        // We can reuse `list_files` logic or call it if it was a function returning Result.
        // `list_files` returns `impl IntoResponse`. Refactoring it to return data would be better.
        // For now, let's duplicate/adapt logic from `list_files` to avoid large refactors,
        // OR better: refactor `list_files` to distinct `get_files_internal` + handler.

        // Let's adapt logic here for expediency, but keeping it clean.
        let files = get_files_for_ui(&state, lib_id, &path).await;

        // Breadcrumbs
        let mut breadcrumbs = Vec::new();
        // Library Root
        let libraries = state.libraries.read().await;
        let lib_name = libraries
            .iter()
            .find(|l| l.id == *lib_id)
            .map(|l| l.name.clone())
            .unwrap_or("Library".to_string());

        breadcrumbs.push(Breadcrumb {
            name: lib_name,
            library_id: lib_id.clone(),
            path: "".to_string(),
        });

        // Split path
        if !path.is_empty() {
            let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
            let mut current_path = String::new();
            for part in parts {
                if !current_path.is_empty() {
                    current_path.push('/');
                }
                current_path.push_str(part);
                breadcrumbs.push(Breadcrumb {
                    name: part.to_string(),
                    library_id: lib_id.clone(),
                    path: current_path.clone(),
                });
            }
        }

        // Parent Link
        let parent_link = if path.is_empty() {
            None // Root of library, Back goes to Libraries list
        } else {
            // Go up one level
            let parts: Vec<&str> = path.split('/').filter(|s| !s.is_empty()).collect();
            if parts.len() <= 1 {
                Some(format!("/?library_id={}", lib_id))
            } else {
                let parent_path = parts[0..parts.len() - 1].join("/");
                Some(format!(
                    "/?library_id={}&path={}",
                    lib_id,
                    urlencoding::encode(&parent_path)
                ))
            }
        };

        let template = IndexTemplate {
            username,
            is_admin,
            is_admin_str,
            mode: "files".to_string(),
            libraries: vec![],
            files,
            breadcrumbs,
            library_id: Some(lib_id.clone()),
            parent_link,
        };
        return template.into_response();
    } else {
        // Libraries Mode
        let libraries_guard = state.libraries.read().await;
        let libraries_view: Vec<LibraryView> = libraries_guard
            .iter()
            .map(|l| {
                let image = match l.kind {
                    crate::models::LibraryType::Movies => "/library_movies.png",
                    crate::models::LibraryType::TVShows => "/library_tv.png",
                    crate::models::LibraryType::Other => "/library_other.png",
                };
                LibraryView {
                    id: l.id.clone(),
                    name: l.name.clone(),
                    image: image.to_string(),
                }
            })
            .collect();

        let template = IndexTemplate {
            username,
            is_admin,
            is_admin_str,
            mode: "libraries".to_string(),
            libraries: libraries_view,
            files: vec![],
            breadcrumbs: vec![], // No breadcrumbs on home
            library_id: None,
            parent_link: None,
        };
        return template.into_response();
    }
}

async fn get_files_for_ui(state: &AppState, lib_id: &str, path: &str) -> Vec<FileView> {
    // Logic adapted from video::list_files
    let Some(base_path) = get_base_path(state, Some(lib_id)).await else {
        return vec![];
    };

    let mut abs_path = base_path.clone();
    abs_path.push(path);

    // canonicalize checks existence
    let Ok(canonical_path) = abs_path.canonicalize() else {
        return vec![];
    };
    let Ok(canonical_root) = base_path.canonicalize() else {
        return vec![];
    };
    if !canonical_path.starts_with(&canonical_root) {
        return vec![];
    }

    let mut entries = Vec::new();

    if let Ok(mut read_dir) = tokio::fs::read_dir(&canonical_path).await {
        while let Ok(Some(entry)) = read_dir.next_entry().await {
            let file_name = entry.file_name().to_string_lossy().to_string();
            if file_name.starts_with('.') {
                continue;
            }

            let file_type = entry.file_type().await.ok();
            let is_dir = file_type.map(|t| t.is_dir()).unwrap_or(false);
            let is_file = file_type.map(|t| t.is_file()).unwrap_or(false);

            let mut rel_path = path.to_string();
            if !rel_path.is_empty() && !rel_path.ends_with('/') {
                rel_path.push('/');
            }
            rel_path.push_str(&file_name);

            let path_encoded = urlencoding::encode(&rel_path).to_string();

            if is_dir {
                let mut display = file_name.clone();
                let mut poster_url = None;

                // Metadata check
                let item_path = canonical_path.join(&file_name);
                if let Some(meta) = crate::metadata::read_local_metadata(&item_path).await {
                    if !meta.title.is_empty() {
                        display = meta.title;
                    }
                    if let Some(_poster) = meta.poster_path {
                        // Construct URL to existing content route
                        // Poster path is e.g. /poster_path.jpg (from TMDB) or local file name?
                        // In list_files: format!("{}.jpg", file_name)
                        // Content route: /api/libraries/:id/content/*path
                        // Path to image relative to library root
                        let img_rel = format!(
                            "{}{}.jpg",
                            if path.is_empty() {
                                "".to_string()
                            } else {
                                format!("{}/", path)
                            },
                            file_name
                        );
                        poster_url = Some(format!(
                            "/api/libraries/{}/content/{}",
                            lib_id,
                            urlencoding::encode(&img_rel)
                        ));
                    }
                }

                entries.push(FileView {
                    name: file_name,
                    display_name: display,
                    path_encoded,
                    is_dir: true,
                    poster_url,
                });
            } else if is_file {
                let ext = std::path::Path::new(&file_name)
                    .extension()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_lowercase();
                if matches!(
                    ext.as_str(),
                    "mp4" | "mkv" | "avi" | "mov" | "webm" | "m4v" | "flv" | "wmv"
                ) {
                    let mut display = file_name.clone();
                    let mut poster_url = None;

                    let item_path = canonical_path.join(&file_name);
                    if let Some(meta) = crate::metadata::read_local_metadata(&item_path).await {
                        if !meta.title.is_empty() {
                            if let Some(ep_num) = meta.episode_number {
                                display = format!("{}. {}", ep_num, meta.title);
                            } else {
                                display = meta.title;
                            }
                        }
                        if let Some(_poster) = meta.poster_path {
                            let img_rel = format!(
                                "{}{}.jpg",
                                if path.is_empty() {
                                    "".to_string()
                                } else {
                                    format!("{}/", path)
                                },
                                file_name
                            );
                            poster_url = Some(format!(
                                "/api/libraries/{}/content/{}",
                                lib_id,
                                urlencoding::encode(&img_rel)
                            ));
                        }
                    }

                    entries.push(FileView {
                        name: file_name,
                        display_name: display,
                        path_encoded,
                        is_dir: false,
                        poster_url,
                    });
                }
            }
        }
    }

    // Sort
    entries.sort_by(|a, b| {
        if a.is_dir == b.is_dir {
            a.name.to_lowercase().cmp(&b.name.to_lowercase())
        } else if a.is_dir {
            std::cmp::Ordering::Less
        } else {
            std::cmp::Ordering::Greater
        }
    });

    entries
}

#[derive(Template)]
#[template(path = "player.html")]
pub struct PlayerTemplate {
    pub title: String,
    pub path_encoded: String,
    pub library_id: String,
    pub back_link: String,
}

impl IntoResponse for PlayerTemplate {
    fn into_response(self) -> Response {
        match self.render() {
            Ok(html) => axum::response::Html(html).into_response(),
            Err(err) => (
                StatusCode::INTERNAL_SERVER_ERROR,
                format!("Failed to render template: {}", err),
            )
                .into_response(),
        }
    }
}

#[derive(Deserialize)]
pub struct WatchParams {
    pub library_id: String,
    pub path: String,
}

pub async fn watch_handler(
    State(_state): State<AppState>,
    jar: CookieJar,
    axum::Form(params): axum::Form<WatchParams>,
) -> Response {
    // 1. Check Auth (Cookie)
    if jar.get(COOKIE_NAME).is_none() {
        return Redirect::to("/login.html").into_response();
    }
    // Verify token:
    let logged_in = if let Some(token) = jar.get(COOKIE_NAME) {
        let validation = Validation::default();
        decode::<Claims>(
            token.value(),
            &DecodingKey::from_secret(JWT_SECRET),
            &validation,
        )
        .is_ok()
    } else {
        false
    };

    if !logged_in {
        return Redirect::to("/login.html").into_response();
    }

    // 2. Prepare Template
    let title = std::path::Path::new(&params.path)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "Movie".to_string());

    let path_str = params.path.clone();
    let parent_path = if let Some(idx) = path_str.rfind('/') {
        path_str[..idx].to_string()
    } else {
        "".to_string()
    };

    let back_link = if parent_path.is_empty() {
        format!("/?library_id={}", params.library_id)
    } else {
        format!(
            "/?library_id={}&path={}",
            params.library_id,
            urlencoding::encode(&parent_path)
        )
    };

    let template = PlayerTemplate {
        title,
        path_encoded: urlencoding::encode(&params.path).to_string(),
        library_id: params.library_id,
        back_link,
    };

    template.into_response()
}
