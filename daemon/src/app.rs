use axum::Router;

use crate::{
    adapters::process::{spawn_command, LaunchCommand},
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
    let config = AppConfig::for_tests();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let state = AppState {
        auth: AuthState::new(config.pin.clone()),
        config,
        sessions: SessionService::new_with_spawner(
            store,
            std::sync::Arc::new(|_command: LaunchCommand| {
                spawn_command(LaunchCommand {
                    program: "sh".into(),
                    args: vec!["-lc".into(), "true".into()],
                })
            }),
        ),
    };

    routes().with_state(state)
}
