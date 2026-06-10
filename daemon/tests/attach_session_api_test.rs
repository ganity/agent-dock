use std::{sync::Arc, time::Duration};

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::{
    adapters::process::{spawn_command, LaunchCommand},
    app::{build_test_router, build_test_router_with_spawner},
};

#[tokio::test]
async fn attach_session_creates_local_record_bound_to_existing_runtime_id() {
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

    let attach = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions/attach")
                .header("content-type", "application/json")
                .header("cookie", cookie)
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude","runtimeSessionId":"thread-abc"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(attach.status(), StatusCode::OK);
    let body = to_bytes(attach.into_body(), usize::MAX).await.unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();
    assert!(text.contains("\"agentKind\":\"claude\""));
    assert!(text.contains("\"session.attached\""));
}

#[tokio::test]
async fn attached_codex_session_can_resume_and_emit_assistant_message() {
    let app = build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-workspace-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-workspace-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-abc\"}}}'; \
                 IFS= read -r _turn; printf '%s\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"attached reply\",\"itemId\":\"i1\",\"threadId\":\"thread-abc\",\"turnId\":\"turn-1\"}}'".into(),
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

    let attach = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions/attach")
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"codex","runtimeSessionId":"thread-abc"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let attach_body = to_bytes(attach.into_body(), usize::MAX).await.unwrap();
    let attach_json: serde_json::Value = serde_json::from_slice(&attach_body).unwrap();
    let session_id = attach_json["id"].as_str().unwrap().to_string();

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
    tokio::time::sleep(Duration::from_millis(100)).await;

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
    assert!(text.contains("\"assistant.message\""));
    assert!(text.contains("attached reply"));
}
