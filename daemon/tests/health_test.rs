use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_dock_daemon::app::build_test_router;

#[tokio::test]
async fn health_endpoint_returns_ok_and_body() {
    let app = build_test_router().await;

    let response = app
        .oneshot(Request::builder().uri("/api/health").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(parsed["ok"], true);
    assert_eq!(parsed["checks"]["database"], "ok");
}
