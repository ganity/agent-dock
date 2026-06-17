use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_dock_daemon::app::build_test_router;

#[tokio::test]
async fn get_session_detail_returns_snapshot_events() {
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
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let create_text = String::from_utf8(create_body.to_vec()).unwrap();
    let session_id = create_text
        .split("\"id\":\"")
        .nth(1)
        .and_then(|value| value.split('"').next())
        .unwrap()
        .to_string();

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
    let body = to_bytes(detail.into_body(), usize::MAX).await.unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();
    let json: serde_json::Value = serde_json::from_str(&text).unwrap();
    assert!(text.contains("\"eventType\":\"session.created\""));
    assert!(text.contains("\"agentKind\":\"claude\""));
    assert_eq!(json["workspacePath"].as_str(), Some("repo"));
    assert_eq!(json["status"].as_str(), Some("created"));
}

#[tokio::test]
async fn get_session_detail_supports_latest_window_and_before_cursor() {
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
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let create_json: serde_json::Value = serde_json::from_slice(&create_body).unwrap();
    let session_id = create_json["id"].as_str().unwrap().to_string();

    for event_index in 1..=6 {
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/api/sessions/{session_id}/messages"))
                    .header("content-type", "application/json")
                    .header("cookie", cookie.clone())
                    .body(Body::from(format!(
                        r#"{{"message":"message-{event_index}","imagePaths":[]}}"#,
                    )))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK);
    }

    let latest_window = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{session_id}?limit=3"))
                .header("cookie", cookie.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(latest_window.status(), StatusCode::OK);
    let latest_body = to_bytes(latest_window.into_body(), usize::MAX).await.unwrap();
    let latest_json: serde_json::Value = serde_json::from_slice(&latest_body).unwrap();
    let latest_events = latest_json["events"].as_array().unwrap();
    assert_eq!(latest_events.len(), 3);
    assert_eq!(latest_json["hasMoreHistory"].as_bool(), Some(true));
    assert!(latest_events[0]["id"].as_i64().unwrap() < latest_events[1]["id"].as_i64().unwrap());
    assert!(latest_events[1]["id"].as_i64().unwrap() < latest_events[2]["id"].as_i64().unwrap());

    let before = latest_events[0]["id"].as_i64().unwrap();
    let older_window = app
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{session_id}?limit=3&before={before}"))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(older_window.status(), StatusCode::OK);
    let older_body = to_bytes(older_window.into_body(), usize::MAX).await.unwrap();
    let older_json: serde_json::Value = serde_json::from_slice(&older_body).unwrap();
    let older_events = older_json["events"].as_array().unwrap();
    assert_eq!(older_events.len(), 3);
    assert_eq!(older_json["hasMoreHistory"].as_bool(), Some(true));
    assert!(older_events[0]["id"].as_i64().unwrap() < older_events[1]["id"].as_i64().unwrap());
    assert!(older_events[1]["id"].as_i64().unwrap() < older_events[2]["id"].as_i64().unwrap());
    assert!(older_events.iter().all(|event| event["id"].as_i64().unwrap() < before));
    assert!(older_events[2]["id"].as_i64().unwrap() < latest_events[0]["id"].as_i64().unwrap());
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
