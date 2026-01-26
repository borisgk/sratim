use axum::{
    Json,
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
};
use axum_extra::extract::cookie::{Cookie, CookieJar};
use jsonwebtoken::{DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use std::sync::Arc;
use tokio::sync::RwLock;

use crate::models::AppState;

const USERS_FILE: &str = "users.json";
const JWT_SECRET: &[u8] = b"secret_key_change_me_in_prod"; // In a real app, load from env
const COOKIE_NAME: &str = "session";

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct User {
    pub username: String,
    pub password_hash: String,
}

#[derive(Debug, Deserialize)]
pub struct LoginPayload {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct Claims {
    sub: String,
    exp: usize,
}

#[derive(Clone)]
pub struct AuthState {
    pub users: Arc<RwLock<HashMap<String, User>>>,
}

impl AuthState {
    pub async fn new() -> Self {
        let users = Arc::new(RwLock::new(HashMap::new()));
        let state = Self {
            users: users.clone(),
        };
        state.load_or_create_default().await;
        state
    }

    async fn load_or_create_default(&self) {
        if let Ok(content) = tokio::fs::read_to_string(USERS_FILE).await
            && let Ok(loaded_users) = serde_json::from_str::<Vec<User>>(&content)
        {
            let mut map = self.users.write().await;
            for user in loaded_users {
                map.insert(user.username.clone(), user);
            }
            println!("Loaded {} users from {}", map.len(), USERS_FILE);
            return;
        }

        // Create default admin user
        println!("Creating default user: admin / admin");
        let hash = bcrypt::hash("admin", bcrypt::DEFAULT_COST).unwrap();
        let admin = User {
            username: "admin".to_string(),
            password_hash: hash,
        };

        let mut map = self.users.write().await;
        map.insert(admin.username.clone(), admin.clone());
        drop(map);

        // Save to file
        self.save().await;
    }

    async fn save(&self) {
        let map = self.users.read().await;
        let users: Vec<User> = map.values().cloned().collect();
        if let Ok(content) = serde_json::to_string_pretty(&users) {
            let _ = tokio::fs::write(USERS_FILE, content).await;
        }
    }
}

pub async fn login_handler(
    State(state): State<AppState>,
    jar: CookieJar,
    Json(payload): Json<LoginPayload>,
) -> impl IntoResponse {
    let auth_map = state.auth.users.read().await;

    if let Some(user) = auth_map.get(&payload.username)
        && bcrypt::verify(&payload.password, &user.password_hash).unwrap_or(false)
    {
        // Create JWT
        let expiration = chrono::Utc::now()
            .checked_add_signed(chrono::Duration::hours(24))
            .expect("valid timestamp")
            .timestamp();

        let claims = Claims {
            sub: user.username.clone(),
            exp: expiration as usize,
        };

        let token = encode(
            &Header::default(),
            &claims,
            &EncodingKey::from_secret(JWT_SECRET),
        )
        .unwrap();

        let cookie = Cookie::build((COOKIE_NAME, token))
            .path("/")
            .http_only(true)
            .same_site(axum_extra::extract::cookie::SameSite::Lax)
            .build();

        let mut response = Json("Login successful").into_response();
        let cookie_res = jar.add(cookie).into_response();
        response.headers_mut().extend(cookie_res.headers().clone());
        return response;
    }

    (StatusCode::UNAUTHORIZED, "Invalid credentials").into_response()
}

pub async fn auth_middleware(jar: CookieJar, req: Request<Body>, next: Next) -> Response {
    if let Some(token) = jar.get(COOKIE_NAME) {
        let validation = Validation::default();
        if decode::<Claims>(
            token.value(),
            &DecodingKey::from_secret(JWT_SECRET),
            &validation,
        )
        .is_ok()
        {
            return next.run(req).await;
        }
    }

    // Cookie missing or invalid
    StatusCode::UNAUTHORIZED.into_response()
}

pub async fn logout_handler(jar: CookieJar) -> impl IntoResponse {
    let cookie = Cookie::build((COOKIE_NAME, ""))
        .path("/")
        .http_only(true)
        .same_site(axum_extra::extract::cookie::SameSite::Lax)
        .max_age(time::Duration::seconds(0))
        .build();

    let mut response = Json("Logged out").into_response();
    let cookie_res = jar.add(cookie).into_response();
    response.headers_mut().extend(cookie_res.headers().clone());
    response
}

pub async fn me_handler(jar: CookieJar) -> impl IntoResponse {
    if let Some(token) = jar.get(COOKIE_NAME) {
        let validation = Validation::default();
        if let Ok(data) = decode::<Claims>(
            token.value(),
            &DecodingKey::from_secret(JWT_SECRET),
            &validation,
        ) {
            return Json(User {
                username: data.claims.sub,
                password_hash: "".to_string(),
            })
            .into_response();
        }
    }
    StatusCode::UNAUTHORIZED.into_response()
}

#[derive(Debug, Deserialize)]
pub struct ChangePasswordPayload {
    pub current_password: String,
    pub new_password: String,
}

pub async fn change_password_handler(
    State(state): State<AppState>,
    jar: CookieJar,
    Json(payload): Json<ChangePasswordPayload>,
) -> impl IntoResponse {
    let user_name = if let Some(token) = jar.get(COOKIE_NAME) {
        let validation = Validation::default();
        if let Ok(data) = decode::<Claims>(
            token.value(),
            &DecodingKey::from_secret(JWT_SECRET),
            &validation,
        ) {
            data.claims.sub
        } else {
            return (StatusCode::UNAUTHORIZED, "Invalid token").into_response();
        }
    } else {
        return (StatusCode::UNAUTHORIZED, "Not logged in").into_response();
    };

    let mut users = state.auth.users.write().await;

    if let Some(user) = users.get_mut(&user_name) {
        if !bcrypt::verify(&payload.current_password, &user.password_hash).unwrap_or(false) {
            return (StatusCode::UNAUTHORIZED, "Invalid current password").into_response();
        }

        match bcrypt::hash(&payload.new_password, bcrypt::DEFAULT_COST) {
            Ok(hash) => {
                user.password_hash = hash;
                // Manual save logic since we hold the write lock
                let all_users: Vec<User> = users.values().cloned().collect();
                if let Ok(content) = serde_json::to_string_pretty(&all_users) {
                    let _ = tokio::fs::write(USERS_FILE, content).await;
                }

                return Json("Password changed successfully").into_response();
            }
            Err(_) => {
                return (StatusCode::INTERNAL_SERVER_ERROR, "Failed to hash password")
                    .into_response();
            }
        }
    }

    (StatusCode::UNAUTHORIZED, "User not found").into_response()
}
