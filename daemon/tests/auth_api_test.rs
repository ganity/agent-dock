use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_workspace_daemon::app::build_test_router;

#[tokio::test]
async fn login_unlocks_workspace_root_listing() {
    let app = build_test_router().await;

    let unauthenticated = app
        .clone()
        .oneshot(Request::builder().uri("/api/workspaces/roots").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(unauthenticated.status(), StatusCode::UNAUTHORIZED);

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

    assert_eq!(login.status(), StatusCode::OK);

    let cookie = login.headers().get("set-cookie").unwrap().to_str().unwrap().to_string();

    let roots = app
        .oneshot(
            Request::builder()
                .uri("/api/workspaces/roots")
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(roots.status(), StatusCode::OK);

    let body = to_bytes(roots.into_body(), usize::MAX).await.unwrap();
    assert_eq!(
        &body[..],
        br#"{"roots":[{"id":"workspace","label":"Workspace","path":"/tmp/workspace"}]}"#,
    );
}
