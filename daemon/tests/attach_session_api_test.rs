use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::app::build_test_router;

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
