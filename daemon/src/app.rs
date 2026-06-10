use axum::Router;

use crate::{auth::AuthState, config::AppConfig, http::routes::routes};

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub auth: AuthState,
}

pub fn build_router(config: AppConfig) -> Router {
    let state = AppState {
        auth: AuthState::new(config.pin.clone()),
        config,
    };

    routes().with_state(state)
}

pub async fn build_test_router() -> Router {
    build_router(AppConfig::for_tests())
}
