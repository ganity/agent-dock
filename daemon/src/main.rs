use std::net::SocketAddr;

use agent_dock_daemon::{app::build_router, config::AppConfig};

#[tokio::main]
async fn main() {
    let config = AppConfig::load().unwrap();
    let address: SocketAddr = config.listen.parse().unwrap();
    let listener = tokio::net::TcpListener::bind(address).await.unwrap();
    axum::serve(listener, build_router(config).await.unwrap()).await.unwrap();
}
