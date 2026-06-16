use axum::body::{to_bytes, Body};
use axum::http::{Request, StatusCode};
use tempfile::TempDir;
use tower::ServiceExt;

use agent_dock_daemon::{
    app::build_router,
    config::{AppConfig, VoiceInputConfig, WorkspaceRoot},
};

#[tokio::test]
async fn login_unlocks_workspace_root_listing() {
    let temp = TempDir::new().unwrap();
    let app = build_router(test_config(&temp)).await;

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

#[tokio::test]
async fn auth_session_reports_current_cookie_state() {
    let temp = TempDir::new().unwrap();
    let app = build_router(test_config(&temp)).await;

    let unauthenticated = app
        .clone()
        .oneshot(Request::builder().uri("/api/auth/session").body(Body::empty()).unwrap())
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

    let authenticated = app
        .oneshot(
            Request::builder()
                .uri("/api/auth/session")
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(authenticated.status(), StatusCode::OK);

    let body = to_bytes(authenticated.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["ok"].as_bool(), Some(true));
    assert_eq!(json["user"]["id"].as_str(), Some("usr_workspace"));
    assert_eq!(json["user"]["displayName"].as_str(), Some("Agent Dock"));
}

#[tokio::test]
async fn login_sets_agent_dock_cookie_and_auth_session_accepts_legacy_cookie_name() {
    let temp = TempDir::new().unwrap();
    let app = build_router(test_config(&temp)).await;

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
    assert!(cookie.starts_with("agent_dock_session="));
    let token = cookie
        .strip_prefix("agent_dock_session=")
        .and_then(|value| value.split(';').next())
        .expect("set-cookie should include agent_dock_session token");

    let legacy_cookie = format!("agent_workspace_session={token}");
    let authenticated = app
        .oneshot(
            Request::builder()
                .uri("/api/auth/session")
                .header("cookie", legacy_cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(authenticated.status(), StatusCode::OK);
}

#[tokio::test]
async fn mobile_login_returns_bearer_token_current_user_and_bootstrap() {
    let temp = TempDir::new().unwrap();
    let app = build_router(test_config(&temp)).await;

    let login = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"workspace","password":"1234"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(login.status(), StatusCode::OK);
    assert!(login.headers().get("set-cookie").is_some());

    let login_body = to_bytes(login.into_body(), usize::MAX).await.unwrap();
    let login_json: serde_json::Value = serde_json::from_slice(&login_body).unwrap();
    let token = login_json["token"].as_str().expect("login should return token");
    assert_eq!(login_json["ok"].as_bool(), Some(true));
    assert_eq!(login_json["user"]["id"].as_str(), Some("usr_workspace"));
    assert_eq!(login_json["user"]["displayName"].as_str(), Some("Workspace"));

    let roots = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/workspaces/roots")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(roots.status(), StatusCode::OK);

    let auth_session = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/api/auth/session")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(auth_session.status(), StatusCode::OK);
    let auth_body = to_bytes(auth_session.into_body(), usize::MAX).await.unwrap();
    let auth_json: serde_json::Value = serde_json::from_slice(&auth_body).unwrap();
    assert_eq!(auth_json["ok"].as_bool(), Some(true));
    assert_eq!(auth_json["user"]["id"].as_str(), Some("usr_workspace"));

    let bootstrap = app
        .oneshot(
            Request::builder()
                .uri("/api/mobile/bootstrap")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(bootstrap.status(), StatusCode::OK);
    let bootstrap_body = to_bytes(bootstrap.into_body(), usize::MAX).await.unwrap();
    let bootstrap_json: serde_json::Value = serde_json::from_slice(&bootstrap_body).unwrap();
    assert_eq!(bootstrap_json["daemonVersion"].as_str(), Some(env!("CARGO_PKG_VERSION")));
    assert_eq!(bootstrap_json["user"]["id"].as_str(), Some("usr_workspace"));
    assert_eq!(bootstrap_json["roots"].as_array().unwrap().len(), 1);
    assert_eq!(bootstrap_json["sessions"].as_array().unwrap().len(), 0);
    assert_eq!(
        bootstrap_json["voice"]["doubaoDirectAvailable"].as_bool(),
        Some(false),
    );
    assert!(bootstrap_json["voice"]["providerCredentials"].is_null());
}

#[tokio::test]
async fn mobile_bootstrap_returns_provider_voice_credentials_when_configured() {
    let temp = TempDir::new().unwrap();
    let app = build_router(AppConfig {
        database_path: temp
            .path()
            .join("agent-dock.sqlite3")
            .to_string_lossy()
            .into_owned(),
        voice_input: Some(VoiceInputConfig {
            websocket_url: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel".into(),
            app_id: "app-123".into(),
            access_token: "token-456".into(),
            resource_id: "volc.bigasr.sauc.duration".into(),
        }),
        ..AppConfig::for_tests()
    })
    .await;

    let login = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/api/auth/login")
                .header("content-type", "application/json")
                .body(Body::from(
                    r#"{"username":"workspace","password":"1234"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(login.status(), StatusCode::OK);

    let login_body = to_bytes(login.into_body(), usize::MAX).await.unwrap();
    let login_json: serde_json::Value = serde_json::from_slice(&login_body).unwrap();
    let token = login_json["token"].as_str().expect("login should return token");

    let bootstrap = app
        .oneshot(
            Request::builder()
                .uri("/api/mobile/bootstrap")
                .header("authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(bootstrap.status(), StatusCode::OK);
    let bootstrap_body = to_bytes(bootstrap.into_body(), usize::MAX).await.unwrap();
    let bootstrap_json: serde_json::Value = serde_json::from_slice(&bootstrap_body).unwrap();
    assert_eq!(
        bootstrap_json["voice"]["doubaoDirectAvailable"].as_bool(),
        Some(true),
    );
    assert_eq!(
        bootstrap_json["voice"]["providerCredentials"]["appId"].as_str(),
        Some("app-123"),
    );
    assert_eq!(
        bootstrap_json["voice"]["providerCredentials"]["accessToken"].as_str(),
        Some("token-456"),
    );
    assert_eq!(
        bootstrap_json["voice"]["providerCredentials"]["resourceId"].as_str(),
        Some("volc.bigasr.sauc.duration"),
    );
    assert_eq!(
        bootstrap_json["voice"]["providerCredentials"]["websocketUrl"].as_str(),
        Some("wss://openspeech.bytedance.com/api/v3/sauc/bigmodel"),
    );
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

#[tokio::test]
async fn login_unlocks_workspace_directory_listing() {
    let temp_home = TempDir::new().unwrap();
    let project_dir = temp_home.path().join("projects");
    let alpha_dir = project_dir.join("alpha");
    let beta_dir = project_dir.join("beta");
    let hidden_dir = project_dir.join(".hidden");
    std::fs::create_dir_all(&alpha_dir).unwrap();
    std::fs::create_dir_all(&beta_dir).unwrap();
    std::fs::create_dir_all(&hidden_dir).unwrap();
    let note_path = project_dir.join("notes.txt");
    std::fs::write(&note_path, "ignore me").unwrap();

    let app = build_router(AppConfig {
        listen: "127.0.0.1:4123".into(),
        pin: "1234".into(),
        database_path: temp_home
            .path()
            .join("agent-dock.sqlite3")
            .to_string_lossy()
            .into_owned(),
        roots: vec![WorkspaceRoot {
            id: "workspace".into(),
            label: "Workspace".into(),
            path: project_dir.to_string_lossy().into_owned(),
        }],
        voice_input: None,
    })
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

    let directories = app
        .clone()
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/workspaces/directories?path={}",
                    urlencoding::encode(project_dir.to_string_lossy().as_ref())
                ))
                .header("cookie", cookie.clone())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(directories.status(), StatusCode::OK);
    let body = to_bytes(directories.into_body(), usize::MAX).await.unwrap();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(
        json["currentPath"].as_str(),
        Some(project_dir.to_string_lossy().as_ref())
    );
    assert_eq!(
        json["parentPath"].as_str(),
        Some(temp_home.path().to_string_lossy().as_ref())
    );
    assert_eq!(json["directories"].as_array().unwrap().len(), 3);
    assert_eq!(json["directories"][0]["name"].as_str(), Some(".hidden"));
    assert_eq!(json["directories"][1]["name"].as_str(), Some("alpha"));
    assert_eq!(json["directories"][2]["name"].as_str(), Some("beta"));

    let blocked = app
        .oneshot(
            Request::builder()
                .uri(format!(
                    "/api/workspaces/directories?path={}",
                    note_path.to_string_lossy()
                ))
                .header("cookie", cookie)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(blocked.status(), StatusCode::BAD_REQUEST);
}
