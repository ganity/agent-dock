use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_dock_daemon::app::build_test_router;

#[tokio::test]
async fn create_session_returns_persisted_placeholder_snapshot() {
    let app = build_test_router().await;

    let login = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"pin":"1234"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    let cookie = login.headers().get("set-cookie").unwrap().to_str().unwrap().to_string();

    let create = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"placeholder"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(create.status(), StatusCode::OK);

    let body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();

    assert!(text.contains("\"agentKind\":\"placeholder\""));
    assert!(text.contains("\"eventType\":\"session.created\""));
}

#[tokio::test]
async fn sessions_are_scoped_to_authenticated_user() {
    let app = build_test_router().await;

    let alice_token = login_for_token(&app, "alice").await;
    let bob_token = login_for_token(&app, "bob").await;

    let create = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {alice_token}"))
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"placeholder","title":"Alice Session"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(create.status(), StatusCode::OK);
    let create_body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let create_json: serde_json::Value = serde_json::from_slice(&create_body).unwrap();
    let session_id = create_json["id"].as_str().unwrap();

    let alice_list = list_sessions_for_token(&app, &alice_token).await;
    assert_eq!(alice_list["sessions"].as_array().unwrap().len(), 1);

    let bob_list = list_sessions_for_token(&app, &bob_token).await;
    assert_eq!(bob_list["sessions"].as_array().unwrap().len(), 0);

    let bob_detail = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{session_id}"))
                .header("authorization", format!("Bearer {bob_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(bob_detail.status(), StatusCode::FORBIDDEN);

    let bob_send = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/messages"))
                .header("content-type", "application/json")
                .header("authorization", format!("Bearer {bob_token}"))
                .body(Body::from(r#"{"message":"not mine"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(bob_send.status(), StatusCode::FORBIDDEN);

    let bob_upload = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/attachments?filename=x.png"))
                .header("content-type", "image/png")
                .header("authorization", format!("Bearer {bob_token}"))
                .body(Body::from("png-data"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(bob_upload.status(), StatusCode::FORBIDDEN);

    let bob_delete = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/sessions/{session_id}"))
                .header("authorization", format!("Bearer {bob_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(bob_delete.status(), StatusCode::FORBIDDEN);
}

async fn login_for_token(app: &axum::Router, username: &str) -> String {
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
    let body = to_bytes(login.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    json["token"].as_str().unwrap().to_string()
}

async fn list_sessions_for_token(app: &axum::Router, token: &str) -> serde_json::Value {
    let list = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/sessions")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(list.status(), StatusCode::OK);
    let body = to_bytes(list.into_body(), usize::MAX).await.unwrap();
    serde_json::from_slice(&body).unwrap()
}
