use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use serde::Deserialize;
use serde_json::json;
use tokio::time::{sleep, Duration};

use crate::{
    app::AppState,
    http::dto::SessionEventDto,
    session::model::StoredEvent,
};

#[derive(Deserialize)]
pub struct EventStreamQuery {
    pub after: Option<i64>,
}

pub async fn stream_session_events(
    ws: WebSocketUpgrade,
    Path(session_id): Path<String>,
    Query(query): Query<EventStreamQuery>,
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if !super::routes::is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    ws.on_upgrade(move |socket| async move {
        let after = query.after.unwrap_or(0);
        let _ = follow_events(socket, state, session_id, after).await;
    })
}

async fn follow_events(
    mut socket: WebSocket,
    state: AppState,
    session_id: String,
    after: i64,
) -> anyhow::Result<()> {
    let mut cursor = after;

    loop {
        let events = state.sessions.events_after(&session_id, cursor).await?;

        for event in events {
            cursor = event.id;
            let dto = event_to_dto(event);
            socket.send(Message::Text(serde_json::to_string(&dto)?.into())).await?;
        }

        tokio::select! {
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {}
                    Some(Err(_)) => break,
                }
            }
            _ = sleep(Duration::from_millis(25)) => {}
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
