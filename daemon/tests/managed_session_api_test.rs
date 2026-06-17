use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_dock_daemon::app::build_test_router;

#[tokio::test]
async fn list_sessions_returns_managed_session_summary() {
    let app = build_test_router().await;

    let cookie = login_for_cookie(&app, "admin").await;

    let create = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude","title":"  Launch Pad  "}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(create.status(), StatusCode::OK);
    let create_body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let create_json: serde_json::Value = serde_json::from_slice(&create_body).unwrap();
    let session_id = create_json["id"].as_str().unwrap().to_string();
    assert_eq!(create_json["title"].as_str(), Some("Launch Pad"));

    let list = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/sessions")
                .header("cookie", cookie.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(list.status(), StatusCode::OK);
    let list_body = to_bytes(list.into_body(), usize::MAX).await.unwrap();
    let list_json: serde_json::Value = serde_json::from_slice(&list_body).unwrap();
    assert_eq!(list_json["sessions"][0]["agentKind"].as_str(), Some("claude"));
    assert_eq!(list_json["sessions"][0]["title"].as_str(), Some("Launch Pad"));

    let detail = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{session_id}"))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(detail.status(), StatusCode::OK);
    let detail_body = to_bytes(detail.into_body(), usize::MAX).await.unwrap();
    let detail_json: serde_json::Value = serde_json::from_slice(&detail_body).unwrap();
    assert_eq!(detail_json["title"].as_str(), Some("Launch Pad"));
}

async fn login_for_cookie(app: &axum::Router, username: &str) -> String {
    let login = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(format!(
                    r#"{{"username":"{username}","password":"1234"}}"#,
                )))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(login.status(), StatusCode::OK);
    login
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string()
}
