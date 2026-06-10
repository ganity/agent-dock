use std::net::SocketAddr;

use agent_workspace_daemon::app::build_router;

#[tokio::main]
async fn main() {
    let address: SocketAddr = "127.0.0.1:4123".parse().unwrap();
    let listener = tokio::net::TcpListener::bind(address).await.unwrap();
    axum::serve(listener, build_router()).await.unwrap();
}
