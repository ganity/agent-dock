use axum::{
    Json,
    extract::{
        Path, Query, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::json;
use tokio::time::{Duration, Instant, sleep};
use tokio_tungstenite::tungstenite::Message as UpstreamMessage;

use crate::{
    app::AppState,
    http::dto::SessionEventDto,
    session::model::StoredEvent,
    voice::{ProviderMessage, build_audio_request, connect_provider, parse_provider_message},
};

const EVENT_POLL_INTERVAL: Duration = Duration::from_millis(25);
const HEARTBEAT_INTERVAL: Duration = Duration::from_millis(250);
/// Maximum number of events to buffer before forcing a resync.
/// If a client falls behind by more than this, it will be told to resync
/// from scratch rather than receiving potentially stale/incomplete data.
const MAX_EVENT_LAG: i64 = 10_000;

#[derive(Deserialize)]
pub struct EventStreamQuery {
    pub after: Option<i64>,
    pub token: Option<String>,
}

pub async fn stream_session_events(
    ws: WebSocketUpgrade,
    Path(session_id): Path<String>,
    Query(query): Query<EventStreamQuery>,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let user = super::routes::current_user_from_headers(&state, &headers).or_else(|| {
        query
            .token
            .as_deref()
            .and_then(|token| state.auth.current_user(token))
    });
    let Some(user) = user else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    match state
        .sessions
        .can_access_session(&session_id, &user.id)
        .await
    {
        Ok(true) => {}
        Ok(false) => {
            return (StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response();
        }
        Err(_) => {
            return StatusCode::NOT_FOUND.into_response();
        }
    }

    ws.on_upgrade(move |socket| async move {
        let after = query.after.unwrap_or(0);
        let _ = follow_events(socket, state, session_id, after).await;
    })
}

pub async fn stream_voice_input(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if !super::routes::is_authenticated(&state, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    }

    let Some(config) = state.config.voice_input.clone() else {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({ "error": "VOICE_INPUT_UNAVAILABLE" })),
        )
            .into_response();
    };

    ws.on_upgrade(move |socket| async move {
        let _ = proxy_voice_input(socket, config).await;
    })
}

async fn follow_events(
    mut socket: WebSocket,
    state: AppState,
    session_id: String,
    after: i64,
) -> anyhow::Result<()> {
    let mut cursor = after;
    let mut last_sent = Instant::now();
    let mut checked_cursor = false;

    loop {
        if !checked_cursor {
            checked_cursor = true;
            if let Some(latest_event_id) = state.sessions.latest_event_id(&session_id).await? {
                if cursor > latest_event_id {
                    socket
                        .send(Message::Text(
                            json!({
                                "id": latest_event_id,
                                "eventType": "session.resync.required",
                                "payload": {
                                    "reason": "cursor_ahead",
                                    "requestedAfter": cursor,
                                    "latestEventId": latest_event_id
                                }
                            })
                            .to_string()
                            .into(),
                        ))
                        .await?;
                    cursor = latest_event_id;
                    last_sent = Instant::now();
                } else if latest_event_id - cursor > MAX_EVENT_LAG {
                    // Client is too far behind; request a full resync
                    socket
                        .send(Message::Text(
                            json!({
                                "id": latest_event_id,
                                "eventType": "session.resync.required",
                                "payload": {
                                    "reason": "cursor_too_far_behind",
                                    "requestedAfter": cursor,
                                    "latestEventId": latest_event_id,
                                    "gap": latest_event_id - cursor
                                }
                            })
                            .to_string()
                            .into(),
                        ))
                        .await?;
                    cursor = latest_event_id;
                    last_sent = Instant::now();
                }
            }
        }

        let events = state.sessions.events_after(&session_id, cursor).await?;
        let had_events = !events.is_empty();

        for event in events {
            cursor = event.id;
            let dto = event_to_dto(event);
            socket
                .send(Message::Text(serde_json::to_string(&dto)?.into()))
                .await?;
        }
        if had_events {
            last_sent = Instant::now();
        } else if last_sent.elapsed() >= HEARTBEAT_INTERVAL {
            socket
                .send(Message::Text(
                    json!({ "id": cursor, "eventType": "session.heartbeat", "payload": {} })
                        .to_string()
                        .into(),
                ))
                .await?;
            last_sent = Instant::now();
        }

        tokio::select! {
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(_)) => break,
                }
            }
            _ = sleep(EVENT_POLL_INTERVAL) => {}
        }
    }

    Ok(())
}

async fn proxy_voice_input(
    mut socket: WebSocket,
    config: crate::config::VoiceInputConfig,
) -> anyhow::Result<()> {
    let (mut upstream, _) = match connect_provider(&config).await {
        Ok(value) => value,
        Err(error) => {
            let _ = socket
                .send(Message::Text(
                    json!({ "type": "error", "message": format!("Voice input failed: {error}") })
                        .to_string()
                        .into(),
                ))
                .await;
            return Ok(());
        }
    };

    socket
        .send(Message::Text(json!({ "type": "ready" }).to_string().into()))
        .await?;

    let mut stop_requested = false;

    loop {
        tokio::select! {
            incoming = socket.recv(), if !stop_requested => {
                match incoming {
                    Some(Ok(Message::Binary(chunk))) => {
                        upstream.send(UpstreamMessage::Binary(build_audio_request(chunk.as_ref(), false)?.into())).await?;
                    }
                    Some(Ok(Message::Text(text))) if is_stop_message(&text) => {
                        upstream.send(UpstreamMessage::Binary(build_audio_request(&[], true)?.into())).await?;
                        stop_requested = true;
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        let _ = upstream
                            .send(UpstreamMessage::Binary(build_audio_request(&[], true)?.into()))
                            .await;
                        break;
                    }
                    Some(Ok(_)) => {}
                    Some(Err(_)) => break,
                }
            }
            upstream_message = upstream.next() => {
                match upstream_message {
                    Some(Ok(UpstreamMessage::Binary(frame))) => {
                        let ProviderMessage { transcript, is_final, error } = parse_provider_message(frame.as_ref())?;

                        if let Some(message) = error {
                            socket
                                .send(Message::Text(
                                    json!({ "type": "error", "message": message }).to_string().into(),
                                ))
                                .await?;
                            break;
                        }

                        if let Some(text) = transcript {
                            socket
                                .send(Message::Text(
                                    json!({ "type": "transcript", "text": text }).to_string().into(),
                                ))
                                .await?;
                        }

                        if stop_requested && is_final {
                            socket
                                .send(Message::Text(json!({ "type": "stopped" }).to_string().into()))
                                .await?;
                            break;
                        }
                    }
                    Some(Ok(UpstreamMessage::Close(_))) | None => {
                        if stop_requested {
                            let _ = socket
                                .send(Message::Text(json!({ "type": "stopped" }).to_string().into()))
                                .await;
                        }
                        break;
                    }
                    Some(Ok(_)) => {}
                    Some(Err(error)) => {
                        socket
                            .send(Message::Text(
                                json!({ "type": "error", "message": format!("Voice input failed: {error}") })
                                    .to_string()
                                    .into(),
                            ))
                            .await?;
                        break;
                    }
                }
            }
        }
    }

    Ok(())
}

fn event_to_dto(event: StoredEvent) -> SessionEventDto {
    SessionEventDto {
        id: event.id,
        event_type: event.event_type,
        payload: serde_json::from_str(&event.payload_json).unwrap(),
    }
}

fn is_stop_message(text: &str) -> bool {
    matches!(
        serde_json::from_str::<serde_json::Value>(text)
            .ok()
            .and_then(|value| value
                .get("type")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string))
            .as_deref(),
        Some("stop")
    )
}
