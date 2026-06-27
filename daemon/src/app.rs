use axum::Router;

use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use tokio::process::Child;

use crate::{
    adapters::process::{spawn_command, LaunchCommand},
    auth::AuthState,
    config::AppConfig,
    http::routes::routes,
    middleware::rate_limit::RateLimiter,
    session::{service::SessionService, store::SqliteSessionStore},
    user::store::SqliteUserStore,
};

/// Default rate limit: 60 requests per minute per user.
const DEFAULT_RATE_LIMIT: usize = 60;
const DEFAULT_RATE_WINDOW: Duration = Duration::from_secs(60);

#[derive(Clone)]
pub struct AppState {
    pub config: AppConfig,
    pub auth: AuthState,
    pub sessions: SessionService,
    pub rate_limiter: RateLimiter,
}

pub async fn build_router(config: AppConfig) -> anyhow::Result<Router> {
    prepare_database_path(&config).await?;
    let store = SqliteSessionStore::from_path(Path::new(&config.database_path)).await?;
    let users = SqliteUserStore::from_path(Path::new(&config.database_path)).await?;
    ensure_bootstrap_admin(&config, &users).await?;

    let rate_limiter = RateLimiter::new(
        config.rate_limit_max_requests.unwrap_or(DEFAULT_RATE_LIMIT),
        config
            .rate_limit_window_secs
            .map(Duration::from_secs)
            .unwrap_or(DEFAULT_RATE_WINDOW),
    );

    let auth = AuthState::new(users);

    // Spawn background task to evict expired auth sessions every hour
    {
        let auth = auth.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(3600));
            loop {
                interval.tick().await;
                auth.evict_expired_sessions();
            }
        });
    }

    let state = AppState {
        auth,
        sessions: SessionService::new(store).with_claude_projects_root(
            config.claude_projects_path.as_ref().map(PathBuf::from),
        ),
        config,
        rate_limiter,
    };

    Ok(routes().with_state(state))
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
    build_test_router_with_config_and_spawner(AppConfig::for_tests(), process_spawner).await
}

pub async fn build_test_router_with_config(config: AppConfig) -> Router {
    build_test_router_with_config_and_spawner(
        config,
        Arc::new(|_command: LaunchCommand| {
            spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec!["-lc".into(), "true".into()],
            })
        }),
    )
    .await
}

pub async fn build_test_router_with_config_and_spawner(
    config: AppConfig,
    process_spawner: Arc<dyn Fn(LaunchCommand) -> anyhow::Result<Child> + Send + Sync>,
) -> Router {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let users = SqliteUserStore::in_memory().await.unwrap();
    ensure_bootstrap_admin(&config, &users).await.unwrap();
    let state = AppState {
        auth: AuthState::new(users),
        sessions: SessionService::new_with_spawner(store, process_spawner)
            .with_attachment_root(
                std::env::temp_dir()
                    .join(format!("agent-dock-daemon-test-{}", uuid::Uuid::new_v4()))
                    .join("attachments"),
            )
            .with_claude_projects_root(config.claude_projects_path.as_ref().map(PathBuf::from)),
        rate_limiter: RateLimiter::new(0, Duration::from_secs(60)), // disabled for tests
        config,
    };

    routes().with_state(state)
}

async fn ensure_bootstrap_admin(
    config: &AppConfig,
    users: &SqliteUserStore,
) -> anyhow::Result<()> {
    if users.count_users().await? > 0 {
        ensure_legacy_workspace_user(config, users).await?;
        return Ok(());
    }

    let password = config
        .bootstrap_admin_password
        .clone()
        .or_else(|| (!config.pin.trim().is_empty()).then(|| config.pin.clone()))
        .ok_or_else(|| anyhow::anyhow!("missing bootstrap admin password"))?;

    users
        .ensure_user("usr_workspace", "admin", &password, true)
        .await?;
    Ok(())
}

async fn ensure_legacy_workspace_user(
    config: &AppConfig,
    users: &SqliteUserStore,
) -> anyhow::Result<()> {
    if users.find_by_id("usr_workspace").await?.is_some() {
        return Ok(());
    }

    let password = config
        .bootstrap_admin_password
        .clone()
        .or_else(|| (!config.pin.trim().is_empty()).then(|| config.pin.clone()))
        .ok_or_else(|| anyhow::anyhow!("missing bootstrap admin password"))?;

    users
        .ensure_user("usr_workspace", "admin", &password, true)
        .await?;
    Ok(())
}

async fn prepare_database_path(config: &AppConfig) -> anyhow::Result<()> {
    let target = PathBuf::from(&config.database_path);
    if target.exists() {
        return Ok(());
    }

    let Some(file_name) = target.file_name().and_then(|value| value.to_str()) else {
        return Ok(());
    };
    if file_name != "agent-dock.sqlite3" {
        return Ok(());
    }

    let Some(parent) = target.parent() else {
        return Ok(());
    };
    let legacy = parent.join("agent-workspace.sqlite3");
    if !legacy.exists() {
        return Ok(());
    }

    tokio::fs::copy(&legacy, &target).await?;
    Ok(())
}
