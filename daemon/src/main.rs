use std::net::SocketAddr;

use agent_dock_daemon::{app::build_router, config::AppConfig};
use tokio::signal;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

#[tokio::main]
async fn main() {
    // ── Initialize structured logging with rotation ──
    init_tracing();

    // ── Load config (exit with descriptive error instead of panic) ──
    let config = match AppConfig::load() {
        Ok(config) => config,
        Err(error) => {
            tracing::error!("failed to load configuration: {error}");
            std::process::exit(1);
        }
    };

    let address: SocketAddr = match config.listen.parse() {
        Ok(address) => address,
        Err(error) => {
            tracing::error!("invalid listen address {:?}: {error}", config.listen);
            std::process::exit(1);
        }
    };

    let listener = match tokio::net::TcpListener::bind(address).await {
        Ok(listener) => listener,
        Err(error) => {
            tracing::error!("failed to bind to {address}: {error}");
            std::process::exit(1);
        }
    };

    let router = match build_router(config).await {
        Ok(router) => router,
        Err(error) => {
            tracing::error!("failed to build application: {error}");
            std::process::exit(1);
        }
    };

    tracing::info!("agent-dock-daemon listening on {address}");

    // ── Graceful shutdown on SIGINT / SIGTERM ──
    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .unwrap_or_else(|error| {
            tracing::error!("server exited: {error}");
            std::process::exit(1);
        });

    tracing::info!("agent-dock-daemon shut down cleanly");
}

/// Initialize structured logging with optional file rotation.
///
/// If `AGENT_DOCK_LOG_DIR` is set, logs are written to rotating files
/// in that directory (max 10MB per file, 3 backups). Otherwise logs
/// go to stderr only.
fn init_tracing() {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info"));

    if let Ok(log_dir) = std::env::var("AGENT_DOCK_LOG_DIR") {
        let log_path = std::path::Path::new(&log_dir);
        let file_appender = tracing_appender::rolling::RollingFileAppender::builder()
            .rotation(tracing_appender::rolling::Rotation::DAILY)
            .filename_prefix("agent-dock")
            .filename_suffix("log")
            .max_log_files(7) // keep 7 days of logs
            .build(log_path)
            .expect("failed to create log file appender");

        let (file_writer, _guard) = tracing_appender::non_blocking(file_appender);

        // Keep _guard alive for the lifetime of the process — dropping it
        // would stop the background writer and lose final log entries.
        std::mem::forget(_guard);

        tracing_subscriber::registry()
            .with(env_filter)
            .with(fmt::layer().with_writer(std::io::stderr))
            .with(fmt::layer().with_writer(file_writer).with_ansi(false))
            .init();
    } else {
        tracing_subscriber::registry()
            .with(env_filter)
            .with(fmt::layer())
            .init();
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        signal::unix::signal(signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {
            tracing::info!("received Ctrl+C, shutting down gracefully...");
        }
        _ = terminate => {
            tracing::info!("received SIGTERM, shutting down gracefully...");
        }
    }
}
