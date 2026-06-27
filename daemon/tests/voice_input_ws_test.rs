use std::sync::{Arc, Mutex};

use axum::body::Body;
use axum::http::Request;
use flate2::{Compression, write::GzEncoder};
use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::{
    accept_hdr_async, connect_async,
    tungstenite::{Message, client::IntoClientRequest, handshake::server::Request as WsRequest},
};
use tower::ServiceExt;

use agent_dock_daemon::{
    app::build_test_router_with_config,
    config::{AppConfig, VoiceInputConfig, WorkspaceRoot},
};

#[tokio::test]
async fn voice_input_websocket_proxies_transcripts_from_asr_server() {
    let upstream_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let upstream_address = upstream_listener.local_addr().unwrap();
    let seen_headers = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
    let seen_headers_for_server = seen_headers.clone();

    let upstream_task = tokio::spawn(async move {
        let (stream, _) = upstream_listener.accept().await.unwrap();
        let mut socket = accept_hdr_async(stream, move |request: &WsRequest, response| {
            let mut headers = seen_headers_for_server.lock().unwrap();
            headers.push((
                "x-api-app-key".into(),
                request
                    .headers()
                    .get("x-api-app-key")
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .to_string(),
            ));
            headers.push((
                "x-api-access-key".into(),
                request
                    .headers()
                    .get("x-api-access-key")
                    .unwrap()
                    .to_str()
                    .unwrap()
                    .to_string(),
            ));
            Ok(response)
        })
        .await
        .unwrap();

        let first = socket.next().await.unwrap().unwrap();
        assert!(matches!(first, Message::Binary(_)));

        let second = socket.next().await.unwrap().unwrap();
        assert!(matches!(second, Message::Binary(_)));
        socket
            .send(Message::Binary(build_server_response("你好", false).into()))
            .await
            .unwrap();

        let third = socket.next().await.unwrap().unwrap();
        assert!(matches!(third, Message::Binary(_)));
        socket
            .send(Message::Binary(build_server_response("你好，继续说", true).into()))
            .await
            .unwrap();
    });

    let app = build_test_router_with_config(AppConfig {
        listen: "127.0.0.1:4123".into(),
        pin: "1234".into(),
        database_path: "./daemon-data/agent-dock.sqlite3".into(),
        claude_projects_path: None,
        roots: vec![WorkspaceRoot {
            id: "workspace".into(),
            label: "Workspace".into(),
            path: "/tmp/workspace".into(),
        }],
        bootstrap_admin_password: Some("1234".into()),
        voice_input: Some(VoiceInputConfig {
            websocket_url: format!("ws://{upstream_address}"),
            app_id: "app-123".into(),
            access_token: "token-456".into(),
            resource_id: "volc.bigasr.sauc.duration".into(),
        }),
        rate_limit_max_requests: None,
        rate_limit_window_secs: None,
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
                    r#"{"username":"admin","password":"1234"}"#,
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let app_for_server = app.clone();
    tokio::spawn(async move {
        axum::serve(listener, app_for_server).await.unwrap();
    });

    let mut request = format!("ws://{address}/ws/voice-input")
        .into_client_request()
        .unwrap();
    request
        .headers_mut()
        .insert("cookie", login.headers().get("set-cookie").unwrap().clone());

    let (mut socket, _) = connect_async(request).await.unwrap();

    let ready = socket.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(ready.contains(r#""type":"ready""#));

    socket.send(Message::Binary(vec![1, 2, 3, 4].into())).await.unwrap();

    let partial = socket.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(partial.contains(r#""type":"transcript""#));
    assert!(partial.contains("你好"));

    socket
        .send(Message::Text(r#"{"type":"stop"}"#.into()))
        .await
        .unwrap();

    let final_result = socket.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(final_result.contains("你好，继续说"));

    let stopped = socket.next().await.unwrap().unwrap().into_text().unwrap();
    assert!(stopped.contains(r#""type":"stopped""#));

    upstream_task.await.unwrap();

    let headers = seen_headers.lock().unwrap();
    assert!(headers.contains(&("x-api-app-key".into(), "app-123".into())));
    assert!(headers.contains(&("x-api-access-key".into(), "token-456".into())));
}

fn build_server_response(text: &str, final_packet: bool) -> Vec<u8> {
    let payload = serde_json::json!({
        "result": {
            "text": text,
        }
    })
    .to_string()
    .into_bytes();
    let compressed = gzip(&payload);
    let flags = if final_packet { 0b0011 } else { 0b0001 };

    let mut frame = vec![0x11, 0x90 | flags, 0x11, 0x00];
    let sequence = if final_packet { -1_i32 } else { 1_i32 };
    frame.extend_from_slice(&sequence.to_be_bytes());
    frame.extend_from_slice(&(compressed.len() as u32).to_be_bytes());
    frame.extend_from_slice(&compressed);
    frame
}

fn gzip(bytes: &[u8]) -> Vec<u8> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    std::io::Write::write_all(&mut encoder, bytes).unwrap();
    encoder.finish().unwrap()
}
