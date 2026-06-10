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
        let _ = replay_events(socket, state, session_id, after).await;
    })
}

async fn replay_events(
    mut socket: WebSocket,
    state: AppState,
    session_id: String,
    after: i64,
) -> anyhow::Result<()> {
    let events = state.sessions.events_after(&session_id, after).await?;

    for event in events {
        let dto = event_to_dto(event);
        socket.send(Message::Text(serde_json::to_string(&dto)?.into())).await?;
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
