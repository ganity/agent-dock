use std::{sync::Arc, time::Duration};

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_dock_daemon::{
    adapters::process::{LaunchCommand, spawn_command},
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
async fn posting_session_message_returns_client_ack_payload() {
    let app = build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec!["-lc".into(), "true".into()],
        })
    }))
    .await;

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

    let send = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/messages"))
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(
                    r#"{"clientMessageId":"cli_1","message":"hello"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(send.status(), StatusCode::OK);
    let body = to_bytes(send.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["accepted"], true);
    assert_eq!(json["clientMessageId"], "cli_1");
    assert!(json["eventId"].as_i64().is_some());

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
    let detail_body = to_bytes(detail.into_body(), usize::MAX).await.unwrap();
    let detail_json: serde_json::Value = serde_json::from_slice(&detail_body).unwrap();
    let user_message = detail_json["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|event| event["eventType"] == "user.message")
        .unwrap();
    assert_eq!(user_message["payload"]["clientMessageId"], "cli_1");
}

#[tokio::test]
async fn posting_same_client_message_id_reuses_original_ack_without_duplication() {
    let app = build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec!["-lc".into(), "true".into()],
        })
    }))
    .await;

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

    let send_body = r#"{"clientMessageId":"cli_1","message":"hello"}"#;
    let first = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/messages"))
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(send_body))
                .unwrap(),
        )
        .await
        .unwrap();
    let first_body = to_bytes(first.into_body(), usize::MAX).await.unwrap();
    let first_json: serde_json::Value = serde_json::from_slice(&first_body).unwrap();

    let second = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/messages"))
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(send_body))
                .unwrap(),
        )
        .await
        .unwrap();
    let second_body = to_bytes(second.into_body(), usize::MAX).await.unwrap();
    let second_json: serde_json::Value = serde_json::from_slice(&second_body).unwrap();

    assert_eq!(first_json["accepted"], true);
    assert_eq!(second_json["accepted"], true);
    assert_eq!(first_json["clientMessageId"], "cli_1");
    assert_eq!(second_json["clientMessageId"], "cli_1");
    assert_eq!(first_json["eventId"], second_json["eventId"]);

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

    let detail_body = to_bytes(detail.into_body(), usize::MAX).await.unwrap();
    let detail_json: serde_json::Value = serde_json::from_slice(&detail_body).unwrap();
    let events = detail_json["events"].as_array().unwrap();
    let user_messages = events
        .iter()
        .filter(|event| event["eventType"] == "user.message")
        .collect::<Vec<_>>();
    let user_messages_count = user_messages.len();
    let user_message_payload = &user_messages[0]["payload"];
    assert_eq!(user_messages_count, 1);
    assert_eq!(user_message_payload["clientMessageId"], "cli_1");
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

    let upload = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!(
                    "/api/sessions/{session_id}/attachments?filename=screenshot.png"
                ))
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
    assert!(
        !std::path::Path::new(image_path).starts_with(
            std::env::current_dir()
                .unwrap()
                .join("daemon-data")
                .join("attachments")
        )
    );
    let image_name = std::path::Path::new(image_path)
        .file_name()
        .unwrap()
        .to_string_lossy()
        .into_owned();

    let fetch = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/sessions/{session_id}/attachments/{image_name}"
                ))
                .header("cookie", cookie.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(fetch.status(), StatusCode::OK);
    assert_eq!(fetch.headers().get("content-type").unwrap(), "image/png");
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
