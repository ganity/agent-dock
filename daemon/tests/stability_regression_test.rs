use std::{sync::Arc, time::Duration};

use axum::body::{Body, to_bytes};
use axum::http::{Request, StatusCode};
use tempfile::tempdir;
use tower::ServiceExt;

use agent_dock_daemon::{
    adapters::process::{LaunchCommand, spawn_command},
    app::AppState,
    auth::AuthState,
    config::AppConfig,
    http::routes::routes,
    middleware::rate_limit::RateLimiter,
    session::{service::SessionService, store::SqliteSessionStore},
    user::store::SqliteUserStore,
};

#[tokio::test]
async fn duplicate_client_message_id_reuses_ack_even_when_rate_limited() {
    let (app, _service) = build_app(
        RateLimiter::new(1, Duration::from_secs(60)),
        Arc::new(|_command: LaunchCommand| {
            spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec!["-lc".into(), "true".into()],
            })
        }),
    )
    .await;

    let cookie = login_for_cookie(&app).await;
    let session_id = create_session(&app, &cookie, "claude").await;
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
    assert_eq!(first.status(), StatusCode::OK);
    let first_body = to_bytes(first.into_body(), usize::MAX).await.unwrap();
    let first_json: serde_json::Value = serde_json::from_slice(&first_body).unwrap();

    let second = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/sessions/{session_id}/messages"))
                .header("content-type", "application/json")
                .header("cookie", cookie)
                .body(Body::from(send_body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);
    let second_body = to_bytes(second.into_body(), usize::MAX).await.unwrap();
    let second_json: serde_json::Value = serde_json::from_slice(&second_body).unwrap();

    assert_eq!(first_json["eventId"], second_json["eventId"]);
    assert_eq!(first_json["clientMessageId"], "cli_1");
    assert_eq!(second_json["clientMessageId"], "cli_1");
}

#[tokio::test]
async fn health_endpoint_returns_503_when_database_check_fails() {
    let (app, service) = build_app(
        RateLimiter::new(0, Duration::from_secs(60)),
        Arc::new(|_command: LaunchCommand| {
            spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec!["-lc".into(), "true".into()],
            })
        }),
    )
    .await;

    service.close_store_for_test().await;

    let response = app
        .oneshot(
            Request::builder()
                .uri("/api/health")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let parsed: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(parsed["ok"], false);
    assert_eq!(parsed["checks"]["database"], "error");
}

#[tokio::test]
async fn delete_session_waits_for_session_lock() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let service = SessionService::new(store);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "claude".into(), None)
        .await
        .unwrap();

    let release = Arc::new(tokio::sync::Notify::new());
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let hold_service = service.clone();
    let hold_session_id = session_id.clone();
    let hold_release = release.clone();
    let hold_task = tokio::spawn(async move {
        hold_service
            .hold_session_lock_for_test(&hold_session_id, ready_tx, hold_release)
            .await;
    });
    ready_rx.await.unwrap();

    let delete_service = service.clone();
    let delete_session_id = session_id.clone();
    let delete_task =
        tokio::spawn(async move { delete_service.delete_session(&delete_session_id).await });

    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!delete_task.is_finished());

    release.notify_one();

    hold_task.await.unwrap();
    assert!(delete_task.await.unwrap().unwrap());
}

#[tokio::test]
async fn resume_session_waits_for_session_lock() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let service = SessionService::new(store);
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "claude".into(), None)
        .await
        .unwrap();

    let release = Arc::new(tokio::sync::Notify::new());
    let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
    let hold_service = service.clone();
    let hold_session_id = session_id.clone();
    let hold_release = release.clone();
    let hold_task = tokio::spawn(async move {
        hold_service
            .hold_session_lock_for_test(&hold_session_id, ready_tx, hold_release)
            .await;
    });
    ready_rx.await.unwrap();

    let resume_service = service.clone();
    let resume_session_id = session_id.clone();
    let resume_task =
        tokio::spawn(async move { resume_service.resume_session(&resume_session_id).await });

    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(!resume_task.is_finished());

    release.notify_one();

    hold_task.await.unwrap();
    assert!(resume_task.await.unwrap().is_ok());
}

#[tokio::test]
async fn codex_runtime_updates_session_heartbeat_tracking() {
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let service = SessionService::new_with_spawner(
        store,
        Arc::new(|_command: LaunchCommand| {
            spawn_command(LaunchCommand {
                program: "sh".into(),
                args: vec![
                    "-lc".into(),
                    "IFS= read -r _init; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-initialize-1\",\"result\":{}}'; \
                     IFS= read -r _thread; printf '%s\n' '{\"jsonrpc\":\"2.0\",\"id\":\"agent-dock-thread-start-2\",\"result\":{\"thread\":{\"id\":\"thread-1\"}}}'; \
                     IFS= read -r _turn; printf '%s\n' '{\"method\":\"item/agentMessage/delta\",\"params\":{\"delta\":\"reply\",\"itemId\":\"i1\",\"threadId\":\"thread-1\",\"turnId\":\"turn-1\"}}'; \
                     sleep 1".into(),
                ],
            })
        }),
    );
    let session_id = service
        .create_managed_session("workspace".into(), "repo".into(), "codex".into(), None)
        .await
        .unwrap();

    service
        .send_user_message(&session_id, "hello".into())
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(service.has_heartbeat_for_test(&session_id));

    assert!(service.delete_session(&session_id).await.unwrap());
}

async fn build_app(
    rate_limiter: RateLimiter,
    process_spawner: Arc<
        dyn Fn(LaunchCommand) -> anyhow::Result<tokio::process::Child> + Send + Sync,
    >,
) -> (axum::Router, SessionService) {
    let temp = tempdir().unwrap();
    let store = SqliteSessionStore::in_memory().await.unwrap();
    let users = SqliteUserStore::in_memory().await.unwrap();
    users
        .ensure_user("usr_workspace", "admin", "1234", true)
        .await
        .unwrap();

    let config = AppConfig {
        rate_limit_max_requests: Some(1),
        rate_limit_window_secs: Some(60),
        ..AppConfig::for_tests()
    };

    let sessions = SessionService::new_with_spawner(store, process_spawner)
        .with_attachment_root(temp.path().join("attachments"));
    let state = AppState {
        config,
        auth: AuthState::new(users),
        sessions: sessions.clone(),
        rate_limiter,
    };

    (routes().with_state(state), sessions)
}

async fn login_for_cookie(app: &axum::Router) -> String {
    let login = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(r#"{"username":"admin","password":"1234"}"#))
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

async fn create_session(app: &axum::Router, cookie: &str, agent_kind: &str) -> String {
    let create = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/sessions")
                .header("content-type", "application/json")
                .header("cookie", cookie)
                .body(Body::from(format!(
                    r#"{{"rootId":"workspace","path":"repo","agentKind":"{agent_kind}"}}"#
                )))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(create.status(), StatusCode::OK);
    let body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    json["id"].as_str().unwrap().to_string()
}
