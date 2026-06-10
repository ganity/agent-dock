use axum::Router;

use crate::{
    auth::AuthState,
    config::AppConfig,
    http::routes::routes,
    session::{service::SessionService, store::SqliteSessionStore},
};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub auth: AuthState,
    pub sessions: SessionService,
}

pub async fn build_router(config: AppConfig) -> Router {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let state = AppState {
        auth: AuthState::new(config.pin.clone()),
        config,
        sessions: SessionService::new(store),
    };

    routes().with_state(state)
}

pub async fn build_test_router() -> Router {
    build_router(AppConfig::for_tests()).await
}
