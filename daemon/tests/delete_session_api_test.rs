use std::sync::{Arc, Mutex};

use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tower::ServiceExt;

use agent_dock_daemon::{
    adapters::process::{spawn_command, LaunchCommand},
    app::build_test_router_with_spawner,
};

#[tokio::test]
async fn delete_session_stops_runtime_and_removes_persisted_data() {
    let recorded_pid = Arc::new(Mutex::new(None::<u32>));
    let recorded_pid_for_spawner = recorded_pid.clone();
    let app = build_test_router_with_spawner(Arc::new(move |_command: LaunchCommand| {
        let child = spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec!["-lc".into(), "exec sleep 30".into()],
        })?;
        *recorded_pid_for_spawner.lock().unwrap() = child.id();
        Ok(child)
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
                    r#"{"rootId":"workspace","path":"repo","agentKind":"codex","title":"Launch Pad"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(create.status(), StatusCode::OK);
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
                .body(Body::from("png-data"))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(upload.status(), StatusCode::OK);
    let upload_body = to_bytes(upload.into_body(), usize::MAX).await.unwrap();
    let upload_json: serde_json::Value = serde_json::from_slice(&upload_body).unwrap();
    let attachment_path = upload_json["path"].as_str().unwrap();
    let attachment_name = std::path::Path::new(attachment_path)
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_string();

    let delete = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri(format!("/api/sessions/{session_id}"))
                .header("cookie", cookie.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(delete.status(), StatusCode::NO_CONTENT);

    let list = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/sessions")
                .header("cookie", cookie.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(list.status(), StatusCode::OK);
    let list_body = to_bytes(list.into_body(), usize::MAX).await.unwrap();
    let list_json: serde_json::Value = serde_json::from_slice(&list_body).unwrap();
    assert_eq!(list_json["sessions"].as_array().unwrap().len(), 0);

    let attachment = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!("/api/sessions/{session_id}/attachments/{attachment_name}"))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(attachment.status(), StatusCode::NOT_FOUND);

    let pid = recorded_pid.lock().unwrap().unwrap();
    let status = std::process::Command::new("sh")
        .arg("-lc")
        .arg(format!("kill -0 {pid} 2>/dev/null"))
        .status()
        .unwrap();
    assert!(!status.success());
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
