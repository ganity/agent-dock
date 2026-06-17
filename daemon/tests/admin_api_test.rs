use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tempfile::TempDir;
use tower::ServiceExt;

use agent_dock_daemon::{app::build_router, config::AppConfig};

#[tokio::test]
async fn admin_can_list_create_reset_and_delete_users() {
    let temp = TempDir::new().unwrap();
    let app = build_router(test_config(&temp)).await.unwrap();

    let admin_login = login_as(app.clone(), "admin", "1234").await;
    assert_eq!(admin_login.status(), StatusCode::OK);
    let admin_token = extract_token(admin_login).await;

    let list = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/admin/users")
                .header("authorization", format!("Bearer {admin_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(list.status(), StatusCode::OK);

    let create = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/admin/users")
                .header("authorization", format!("Bearer {admin_token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"alice","password":"alice123","isAdmin":false}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create.status(), StatusCode::CREATED);
    let created_body = to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let created_json: serde_json::Value = serde_json::from_slice(&created_body).unwrap();
    let user_id = created_json["user"]["id"].as_str().unwrap().to_string();

    let reset = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/api/admin/users/{user_id}/password"))
                .header("authorization", format!("Bearer {admin_token}"))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"password":"alice456"}"#))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(reset.status(), StatusCode::OK);

    let delete = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/admin/users/{user_id}"))
                .header("authorization", format!("Bearer {admin_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(delete.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn non_admin_is_forbidden_from_admin_routes() {
    let temp = TempDir::new().unwrap();
    let app = build_router(test_config(&temp)).await.unwrap();

    let admin_login = login_as(app.clone(), "admin", "1234").await;
    let admin_token = extract_token(admin_login).await;

    let create = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/admin/users")
                .header("authorization", format!("Bearer {admin_token}"))
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"alice","password":"alice123","isAdmin":false}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(create.status(), StatusCode::CREATED);

    let user_login = login_as(app.clone(), "alice", "alice123").await;
    assert_eq!(user_login.status(), StatusCode::OK);
    let user_token = extract_token(user_login).await;

    let list = app
        .oneshot(
            Request::builder()
                .uri("/api/admin/users")
                .header("authorization", format!("Bearer {user_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(list.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn deleting_last_admin_is_rejected() {
    let temp = TempDir::new().unwrap();
    let app = build_router(test_config(&temp)).await.unwrap();

    let admin_login = login_as(app.clone(), "admin", "1234").await;
    let admin_token = extract_token(admin_login).await;

    let auth_session = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/session")
                .header("authorization", format!("Bearer {admin_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let auth_body = to_bytes(auth_session.into_body(), usize::MAX).await.unwrap();
    let auth_json: serde_json::Value = serde_json::from_slice(&auth_body).unwrap();
    let admin_id = auth_json["user"]["id"].as_str().unwrap().to_string();

    let delete = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/admin/users/{admin_id}"))
                .header("authorization", format!("Bearer {admin_token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(delete.status(), StatusCode::BAD_REQUEST);
}

fn test_config(temp: &TempDir) -> AppConfig {
    AppConfig {
        database_path: temp
            .path()
            .join("agent-dock.sqlite3")
            .to_string_lossy()
            .into_owned(),
        ..AppConfig::for_tests()
    }
}

async fn login_as(app: axum::Router, username: &str, password: &str) -> axum::response::Response {
    app.oneshot(
        Request::builder()
            .method("POST")
            .uri("/api/auth/login")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({
                    "username": username,
                    "password": password,
                })
                .to_string(),
            ))
            .unwrap(),
    )
    .await
    .unwrap()
}

async fn extract_token(response: axum::response::Response) -> String {
    let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    json["token"].as_str().unwrap().to_string()
}
