use axum::Router;

use std::sync::Arc;

use tokio::process::Child;

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
    let store = SqliteSessionStore::from_path(std::path::Path::new(&config.database_path))
        .await
        .unwrap();
    let state = AppState {
        auth: AuthState::new(config.pin.clone()),
        config,
        sessions: SessionService::new(store),
    };

    routes().with_state(state)
}

pub async fn build_test_router() -> Router {
    build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec!["-lc".into(), "true".into()],
        })
    }))
    .await
}

pub async fn build_test_router_with_spawner(
    process_spawner: Arc<dyn Fn(LaunchCommand) -> anyhow::Result<Child> + Send + Sync>,
) -> Router {
    let config = AppConfig::for_tests();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let state = AppState {
        auth: AuthState::new(config.pin.clone()),
        config,
        sessions: SessionService::new_with_spawner(store, process_spawner),
    };

    routes().with_state(state)
}
