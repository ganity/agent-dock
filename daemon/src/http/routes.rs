use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde_json::json;

use crate::{
    app::AppState,
    http::dto::{
        CreateSessionRequest, LoginRequest, SessionEventDto, SessionSnapshotDto, SessionSummaryDto,
        WorkspaceRootDto,
    },
    http::ws::stream_session_events,
    workspace,
};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/auth/login", post(login))
        .route("/api/workspaces/roots", get(workspace_roots))
        .route("/api/sessions", post(create_session).get(list_sessions))
        .route("/api/sessions/{id}", get(get_session))
        .route("/ws/sessions/{id}/events", get(stream_session_events))
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "ok": true }))
}

fn session_token_from_headers(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::COOKIE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split("agent_workspace_session=").nth(1))
        .and_then(|value| value.split(';').next())
}

pub(crate) fn is_authenticated(state: &AppState, headers: &HeaderMap) -> bool {
    session_token_from_headers(headers).is_some_and(|value| state.auth.is_authenticated(value))
}

async fn login(
    State(state): State<AppState>,
    Json(request): Json<LoginRequest>,
) -> impl IntoResponse {
    match state.auth.login(&request.pin) {
        Some(token) => {
            let headers = [(
                header::SET_COOKIE,
                format!("agent_workspace_session={token}; Path=/; HttpOnly"),
            )];
            (StatusCode::OK, headers, Json(json!({ "ok": true }))).into_response()
        }
        None => (StatusCode::UNAUTHORIZED, Json(json!({ "error": "INVALID_PIN" }))).into_response(),
    }
}

async fn workspace_roots(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let roots = workspace::list_roots(&state.config.roots)
        .into_iter()
        .map(|root| WorkspaceRootDto {
            id: root.id,
            label: root.label,
            path: root.path,
        })
        .collect::<Vec<_>>();

    (StatusCode::OK, Json(json!({ "roots": roots }))).into_response()
}

async fn create_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateSessionRequest>,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let session_id = match state
        .sessions
        .create_placeholder_session(request.root_id, request.path, request.agent_kind)
        .await
    {
        Ok(value) => value,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };

    let snapshot = match state.sessions.load_snapshot(&session_id).await {
        Ok(value) => value,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };

    let response = snapshot_to_dto(snapshot);

    (StatusCode::OK, Json(response)).into_response()
}

async fn list_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let sessions = match state.sessions.list_sessions().await {
        Ok(value) => value,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };

    let response = sessions
        .into_iter()
        .map(|session| SessionSummaryDto {
            id: session.id,
            agent_kind: session.agent_kind,
            status: session.status,
            workspace_path: session.workspace_path,
        })
        .collect::<Vec<_>>();

    (StatusCode::OK, Json(json!({ "sessions": response }))).into_response()
}

async fn get_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let snapshot = match state.sessions.load_snapshot(&session_id).await {
        Ok(value) => value,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };

    (StatusCode::OK, Json(snapshot_to_dto(snapshot))).into_response()
}

fn snapshot_to_dto(snapshot: crate::session::model::SessionSnapshot) -> SessionSnapshotDto {
    SessionSnapshotDto {
        id: snapshot.session.id,
        agent_kind: snapshot.session.agent_kind,
        events: snapshot
            .events
            .into_iter()
            .map(|event| SessionEventDto {
                id: event.id,
                event_type: event.event_type,
                payload: serde_json::from_str(&event.payload_json).unwrap(),
            })
            .collect(),
    }
}
