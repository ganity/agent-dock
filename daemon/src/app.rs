use axum::{routing::get, Json, Router};
use serde_json::json;

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "ok": true }))
}

pub fn build_router() -> Router {
    Router::new().route("/api/health", get(health))
}

pub async fn build_test_router() -> Router {
    build_router()
}
