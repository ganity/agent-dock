use std::{sync::Arc, time::Duration};

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_dock_daemon::{
    adapters::process::{spawn_command, LaunchCommand},
    app::build_test_router_with_spawner,
};

#[tokio::test]
async fn posting_session_message_persists_user_event_and_runtime_reply() {
    let app = build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "printf '%s\n%s\n' \
                 '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply\"}]}}' \
                 '{\"type\":\"result\",\"session_id\":\"claude-thread-1\",\"result\":\"reply\"}'".into(),
            ],
        })
    }))
    .await;

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
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let create_json: serde_json::Value = serde_json::from_slice(&create_body).unwrap();
    let session_id = create_json["id"].as_str().unwrap().to_string();

    let send = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/messages"))
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(r#"{"message":"hello"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(send.status(), StatusCode::OK);

    tokio::time::sleep(Duration::from_millis(50)).await;

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

    let body = to_bytes(detail.into_body(), usize::MAX).await.unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();

    assert!(text.contains("\"eventType\":\"user.message\""));
    assert!(text.contains("\"eventType\":\"assistant.message\""));
    assert!(text.contains("\"reply\""));
}

#[tokio::test]
async fn uploading_image_attachment_returns_local_path_for_session_message() {
    let app = build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "printf '%s\n%s\n' \
                 '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"reply\"}]}}' \
                 '{\"type\":\"result\",\"session_id\":\"claude-thread-1\",\"result\":\"reply\"}'".into(),
            ],
        })
    }))
    .await;

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
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let create_json: serde_json::Value = serde_json::from_slice(&create_body).unwrap();
    let session_id = create_json["id"].as_str().unwrap().to_string();

    let upload = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/attachments?filename=screenshot.png"))
                .header("content-type", "image/png")
                .header("cookie", cookie.clone())
                .body(Body::from(vec![137, 80, 78, 71]))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(upload.status(), StatusCode::OK);
    let upload_body = to_bytes(upload.into_body(), usize::MAX).await.unwrap();
    let upload_json: serde_json::Value = serde_json::from_slice(&upload_body).unwrap();
    let image_path = upload_json["path"].as_str().unwrap();
    assert!(image_path.ends_with(".png"));
    assert!(std::path::Path::new(image_path).exists());
    assert!(!std::path::Path::new(image_path).starts_with(
        std::env::current_dir()
            .unwrap()
            .join("daemon-data")
            .join("attachments")
    ));
    let image_name = std::path::Path::new(image_path)
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();

    let fetch = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{session_id}/attachments/{image_name}"))
                .header("cookie", cookie.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(fetch.status(), StatusCode::OK);
    assert_eq!(
        fetch.headers().get("content-type").unwrap(),
        "image/png"
    );
    let fetch_body = to_bytes(fetch.into_body(), usize::MAX).await.unwrap();
    assert_eq!(fetch_body.as_ref(), &[137, 80, 78, 71]);

    let send = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/messages"))
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(format!(
                    r#"{{"message":"hello","imagePaths":["{image_path}"]}}"#
                )))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(send.status(), StatusCode::OK);
    tokio::time::sleep(Duration::from_millis(50)).await;

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

    let body = to_bytes(detail.into_body(), usize::MAX).await.unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();
    assert!(text.contains("\"imagePaths\""));
    assert!(text.contains("screenshot"));
}
