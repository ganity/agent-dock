use axum::body::Body;
use axum::http::Request;
use futures_util::StreamExt;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tower::ServiceExt;

use agent_workspace_daemon::{
    adapters::process::{spawn_command, LaunchCommand},
    app::build_test_router_with_spawner,
};

#[tokio::test]
async fn websocket_stream_replays_events_after_cursor() {
    let app = build_test_router_with_spawner(std::sync::Arc::new(|_command: LaunchCommand| {
        spawn_command(LaunchCommand {
            program: "sh".into(),
            args: vec![
                "-lc".into(),
                "sleep 0.1; printf '%s\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"later\"}]}}'".into(),
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
                .header("cookie", cookie)
                .body(Body::from(
                    r#"{"rootId":"workspace","path":"repo","agentKind":"claude"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let create_body = axum::body::to_bytes(create.into_body(), usize::MAX).await.unwrap();
    let create_json: serde_json::Value = serde_json::from_slice(&create_body).unwrap();
    let session_id = create_json["id"].as_str().unwrap().to_string();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app_for_server = app.clone();
    tokio::spawn(async move {
        axum::serve(listener, app_for_server).await.unwrap();
    });

    let mut request = format!("ws://{address}/ws/sessions/{session_id}/events?after=0")
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("cookie", login.headers().get("set-cookie").unwrap().clone());

    let (mut socket, _) = connect_async(request)
        .await
        .unwrap();

    let first = socket.next().await.unwrap().unwrap();
    let text = first.into_text().unwrap();

    assert!(text.contains("\"eventType\":\"session.created\""));

    let second = socket.next().await.unwrap().unwrap();
    let second_text = second.into_text().unwrap();

    assert!(second_text.contains("\"eventType\":\"session.status.changed\""));

    let third = socket.next().await.unwrap().unwrap();
    let third_text = third.into_text().unwrap();

    assert!(third_text.contains("\"eventType\":\"assistant.message\""));
    assert!(third_text.contains("\"later\""));
}
