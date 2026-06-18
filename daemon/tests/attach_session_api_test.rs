use std::{sync::Arc, time::Duration};

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;
use tempfile::tempdir;

use agent_dock_daemon::{
    adapters::process::{spawn_command, LaunchCommand},
    app::{build_test_router, build_test_router_with_config_and_spawner, build_test_router_with_spawner},
    config::AppConfig,
};

#[tokio::test]
async fn attach_session_creates_local_record_bound_to_existing_runtime_id() {
    let app = build_test_router().await;

    let cookie = login_for_cookie(&app, "admin").await;

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
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let text = String::from_utf8(body.to_vec()).unwrap();
    assert_eq!(json["title"], serde_json::Value::Null);
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
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-abc\"}}}'; \
                 IFS= read -r _turn; printf '%s\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"attached reply\",\"itemId\":\"i1\",\"threadId\":\"thread-abc\",\"turnId\":\"turn-1\"}}'".into(),
            ],
        })
    }))
    .await;

    let cookie = login_for_cookie(&app, "admin").await;

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

#[tokio::test]
async fn resume_session_endpoint_recovers_attached_codex_runtime() {
    let app = build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                 IFS= read -r _resume; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-resume-2\",\"result\":{\"thread\":{\"id\":\"thread-abc\"}}}'; \
                 printf '%s\n' '{\"jsonrpc\":\"2.0\",\"method\":\"thread/status/changed\",\"params\":{\"status\":{\"type\":\"active\"},\"threadId\":\"thread-abc\"}}'; \
                 sleep 1".into(),
            ],
        })
    }))
    .await;

    let cookie = login_for_cookie(&app, "admin").await;

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

    let resume = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/resume"))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resume.status(), StatusCode::OK);
    let body = to_bytes(resume.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["status"].as_str(), Some("running"));
    assert!(json["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|event| event["eventType"].as_str() == Some("session.status.changed")));
    assert!(!json["events"]
        .as_array()
        .unwrap()
        .iter()
        .any(|event| event["eventType"].as_str() == Some("user.message")));
}

#[tokio::test]
async fn resume_session_endpoint_returns_latest_window_instead_of_full_history() {
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

    for event_index in 1..=60 {
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

    let resume = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/resume"))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resume.status(), StatusCode::OK);
    let body = to_bytes(resume.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    let events = json["events"].as_array().unwrap();

    assert_eq!(events.len(), 50);
    assert_eq!(json["hasMoreHistory"].as_bool(), Some(true));
    assert!(events.first().unwrap()["id"].as_i64().unwrap() > 1);
}

#[tokio::test]
async fn attached_claude_session_can_resume_and_emit_assistant_message() {
    let app = build_test_router_with_spawner(Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "printf '%s\n%s\n' \
                 '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"attached hello\"}]}}' \
                 '{\"type\":\"result\",\"session_id\":\"thread-abc\",\"result\":\"attached hello\"}'".into(),
            ],
        })
    }))
    .await;

    let cookie = login_for_cookie(&app, "admin").await;

    let attach = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions/attach")
                .header("content-type", "application/json")
                .header("cookie", cookie.clone())
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude","runtimeSessionId":"thread-abc"}"#,
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
    assert!(text.contains("attached hello"));
}

#[tokio::test]
async fn resume_candidates_api_lists_real_codex_threads_for_workspace_path() {
    let temp = tempdir().unwrap();
    let root_path = temp.path().join("workspace");
    let repo_path = root_path.join("apps").join("api");
    std::fs::create_dir_all(&repo_path).unwrap();

    let app = build_test_router_with_config_and_spawner(
        AppConfig {
            roots: vec![agent_dock_daemon::config::WorkspaceRoot {
                id: "workspace".into(),
                label: "Workspace".into(),
                path: root_path.to_string_lossy().into_owned(),
            }],
            claude_projects_path: Some(temp.path().join("claude-projects").to_string_lossy().into_owned()),
            ..AppConfig::for_tests()
        },
        Arc::new(|_command: LaunchCommand| {
            spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec![
                    "-lc".into(),
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _list; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-list-2\",\"result\":{\"data\":[{\"id\":\"thread-123\",\"sessionId\":\"session-123\",\"forkedFromId\":null,\"parentThreadId\":null,\"preview\":\"Fix API auth\",\"ephemeral\":false,\"modelProvider\":\"openai\",\"createdAt\":1,\"updatedAt\":2,\"status\":{\"type\":\"idle\"},\"path\":null,\"cwd\":\"/tmp/ignored\",\"cliVersion\":\"0.0.0\",\"source\":\"cli\",\"threadSource\":\"cli\",\"agentNickname\":null,\"agentRole\":null,\"gitInfo\":null,\"name\":\"API Fixes\",\"turns\":[]},{\"id\":\"thread-456\",\"sessionId\":\"session-456\",\"forkedFromId\":null,\"parentThreadId\":null,\"preview\":\"Investigate timeouts\",\"ephemeral\":false,\"modelProvider\":\"openai\",\"createdAt\":3,\"updatedAt\":4,\"status\":{\"type\":\"active\",\"activeFlags\":[]},\"path\":null,\"cwd\":\"/tmp/ignored\",\"cliVersion\":\"0.0.0\",\"source\":\"cli\",\"threadSource\":\"cli\",\"agentNickname\":null,\"agentRole\":null,\"gitInfo\":null,\"name\":null,\"turns\":[]}],\"nextCursor\":null,\"backwardsCursor\":null}}'".into(),
                ],
            })
        }),
    )
    .await;

    let cookie = login_for_cookie(&app, "admin").await;
    let response = app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/sessions/resume-candidates?rootId=workspace&agentKind=codex&path={}",
                    urlencoding::encode("apps/api"),
                ))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["candidates"][0]["runtimeSessionId"], "thread-123");
    assert_eq!(json["candidates"][0]["title"], "API Fixes");
    assert_eq!(json["candidates"][1]["runtimeSessionId"], "thread-456");
}

#[tokio::test]
async fn resume_candidates_api_lists_real_claude_sessions_for_workspace_path() {
    let temp = tempdir().unwrap();
    let root_path = temp.path().join("workspace");
    let repo_path = root_path.join("apps").join("web");
    let projects_root = temp.path().join("claude-projects").join("slug");
    std::fs::create_dir_all(&repo_path).unwrap();
    std::fs::create_dir_all(&projects_root).unwrap();
    std::fs::write(
        projects_root.join("claude-session-1.jsonl"),
        format!(
            concat!(
                "{{\"type\":\"user\",\"message\":{{\"role\":\"user\",\"content\":\"Fix homepage hero\"}},\"timestamp\":\"2026-06-16T09:00:00.000Z\",\"cwd\":\"{cwd}\",\"sessionId\":\"claude-session-1\"}}\n",
                "{{\"type\":\"assistant\",\"message\":{{\"content\":[{{\"type\":\"text\",\"text\":\"working\"}}]}},\"timestamp\":\"2026-06-16T09:01:00.000Z\",\"cwd\":\"{cwd}\",\"sessionId\":\"claude-session-1\"}}\n"
            ),
            cwd = repo_path.to_string_lossy(),
        ),
    )
    .unwrap();

    let app = build_test_router_with_config_and_spawner(
        AppConfig {
            roots: vec![agent_dock_daemon::config::WorkspaceRoot {
                id: "workspace".into(),
                label: "Workspace".into(),
                path: root_path.to_string_lossy().into_owned(),
            }],
            claude_projects_path: Some(temp.path().join("claude-projects").to_string_lossy().into_owned()),
            ..AppConfig::for_tests()
        },
        Arc::new(|_command: LaunchCommand| {
            spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec!["-lc".into(), "true".into()],
            })
        }),
    )
    .await;

    let cookie = login_for_cookie(&app, "admin").await;
    let response = app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/sessions/resume-candidates?rootId=workspace&agentKind=claude&path={}",
                    urlencoding::encode("apps/web"),
                ))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["candidates"][0]["runtimeSessionId"], "claude-session-1");
    assert_eq!(json["candidates"][0]["title"], "Fix homepage hero");
    assert_eq!(
        json["candidates"][0]["workspacePath"],
        repo_path.to_string_lossy().to_string()
    );
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
