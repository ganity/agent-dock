use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde_json::json;
use std::collections::HashMap;

use crate::{
    app::AppState,
    http::dto::{
        AttachSessionRequest, CreateSessionRequest, CurrentUserDto, LoginRequest, SendMessageRequest,
        SessionEventDto, SessionSnapshotDto, SessionSummaryDto, WorkspaceDirectoryDto,
        WorkspaceDirectoryListingDto, WorkspaceRootDto,
    },
    http::ws::{stream_session_events, stream_voice_input},
    workspace,
};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/health", get(health))
        .route("/api/auth/login", post(login))
        .route("/api/auth/session", get(auth_session))
        .route("/api/mobile/bootstrap", get(mobile_bootstrap))
        .route("/api/workspaces/roots", get(workspace_roots))
        .route("/api/workspaces/directories", get(workspace_directories))
        .route("/api/sessions", post(create_session).get(list_sessions))
        .route("/api/sessions/attach", post(attach_session))
        .route("/api/sessions/{id}", get(get_session).delete(delete_session))
        .route("/api/sessions/{id}/attachments/{name}", get(get_session_attachment))
        .route("/api/sessions/{id}/attachments", post(upload_session_attachment))
        .route("/api/sessions/{id}/messages", post(send_session_message))
        .route("/ws/sessions/{id}/events", get(stream_session_events))
        .route("/ws/voice-input", get(stream_voice_input))
}

async fn health() -> Json<serde_json::Value> {
    Json(json!({ "ok": true }))
}

fn session_token_from_headers(headers: &HeaderMap) -> Option<&str> {
    bearer_token_from_headers(headers).or_else(|| {
        headers
            .get(header::COOKIE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| {
                cookie_value(value, "agent_dock_session")
                    .or_else(|| cookie_value(value, "agent_workspace_session"))
            })
    })
}

fn cookie_value<'a>(cookie_header: &'a str, name: &str) -> Option<&'a str> {
    cookie_header
        .split(';')
        .map(str::trim)
        .find_map(|cookie| cookie.strip_prefix(&format!("{name}=")))
}

fn bearer_token_from_headers(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

pub(crate) fn is_authenticated(state: &AppState, headers: &HeaderMap) -> bool {
    session_token_from_headers(headers).is_some_and(|value| state.auth.is_authenticated(value))
}

pub(crate) fn current_user_from_headers(
    state: &AppState,
    headers: &HeaderMap,
) -> Option<crate::auth::CurrentUser> {
    session_token_from_headers(headers).and_then(|value| state.auth.current_user(value))
}

async fn login(
    State(state): State<AppState>,
    Json(request): Json<LoginRequest>,
) -> impl IntoResponse {
    let token = match (&request.username, &request.password, &request.pin) {
        (Some(username), Some(password), _) => state.auth.login_user(username, password),
        (_, _, Some(pin)) => state.auth.login(pin),
        _ => None,
    };

    match token {
        Some(token) => {
            let user = state
                .auth
                .current_user(&token)
                .expect("newly-created auth token should resolve to user");
            let headers = [(
                header::SET_COOKIE,
                format!("agent_dock_session={token}; Path=/; HttpOnly"),
            )];
            (
                StatusCode::OK,
                headers,
                Json(json!({
                    "ok": true,
                    "token": token,
                    "user": current_user_to_dto(user),
                })),
            )
                .into_response()
        }
        None => {
            (StatusCode::UNAUTHORIZED, Json(json!({ "error": "INVALID_CREDENTIALS" }))).into_response()
        }
    }
}

async fn auth_session(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    (StatusCode::OK, Json(json!({ "ok": true, "user": current_user_to_dto(user) }))).into_response()
}

async fn mobile_bootstrap(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    let roots = workspace_root_dtos(&state);
    let sessions = match state.sessions.list_sessions_for_user(&user.id).await {
        Ok(value) => value,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };
    let sessions = sessions
        .into_iter()
        .map(session_summary_to_dto)
        .collect::<Vec<_>>();

    (
        StatusCode::OK,
        Json(json!({
            "daemonVersion": env!("CARGO_PKG_VERSION"),
            "user": current_user_to_dto(user),
            "roots": roots,
            "sessions": sessions,
            "voice": {
                "doubaoDirectAvailable": state.config.voice_input.is_some(),
                "providerCredentials": state.config.voice_input.as_ref().map(|voice_input| json!({
                    "appId": voice_input.app_id,
                    "accessToken": voice_input.access_token,
                    "resourceId": voice_input.resource_id,
                    "websocketUrl": voice_input.websocket_url,
                })),
            },
        })),
    )
        .into_response()
}

async fn workspace_roots(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let roots = workspace_root_dtos(&state);

    (StatusCode::OK, Json(json!({ "roots": roots }))).into_response()
}

async fn workspace_directories(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    }

    let Some(path) = query.get("path").map(String::as_str) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "path query parameter is required" })),
        )
            .into_response();
    };

    let listing = match workspace::list_directories(path) {
        Ok(value) => value,
        Err(error) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };

    let response = WorkspaceDirectoryListingDto {
        current_path: listing.current_path,
        parent_path: listing.parent_path,
        directories: listing
            .directories
            .into_iter()
            .map(|entry| WorkspaceDirectoryDto {
                name: entry.name,
                path: entry.path,
            })
            .collect(),
    };

    (StatusCode::OK, Json(response)).into_response()
}

async fn create_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateSessionRequest>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    let title = request.title.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    });

    let session_id = match state
        .sessions
        .create_managed_session_for_user(
            user.id,
            request.root_id,
            request.path,
            request.agent_kind,
            title,
        )
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
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    let sessions = match state.sessions.list_sessions_for_user(&user.id).await {
        Ok(value) => value,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };

    let response = sessions.into_iter().map(session_summary_to_dto).collect::<Vec<_>>();

    (StatusCode::OK, Json(json!({ "sessions": response }))).into_response()
}

async fn attach_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<AttachSessionRequest>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    let session_id = match state
        .sessions
        .attach_existing_session_for_user(
            user.id,
            request.root_id,
            request.path,
            request.agent_kind,
            request.runtime_session_id,
        )
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

    (StatusCode::OK, Json(snapshot_to_dto(snapshot))).into_response()
}

async fn get_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    let limit = query
        .get("limit")
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0);
    let before = query.get("before").and_then(|value| value.parse::<i64>().ok());

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    let snapshot = match state.sessions.load_snapshot_window(&session_id, limit, before).await {
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

async fn delete_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    match state.sessions.delete_session(&session_id).await {
        Ok(true) => StatusCode::NO_CONTENT.into_response(),
        Ok(false) => StatusCode::NOT_FOUND.into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": error.to_string() })),
        )
            .into_response(),
    }
}

async fn send_session_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Json(request): Json<SendMessageRequest>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    match state
        .sessions
        .send_user_message_with_images(&session_id, request.message, request.image_paths)
        .await
    {
        Ok(()) => (StatusCode::OK, Json(json!({ "ok": true }))).into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": error.to_string() })),
        )
            .into_response(),
    }
}

async fn upload_session_attachment(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
    body: Bytes,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    if !content_type.starts_with("image/") {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "ATTACHMENT_MUST_BE_IMAGE" })),
        )
            .into_response();
    }

    let filename = query
        .get("filename")
        .map(String::as_str)
        .unwrap_or("attachment.png");
    let path = match state.sessions.store_image_attachment(&session_id, filename, &body).await {
        Ok(path) => path,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    };

    (StatusCode::OK, Json(json!({ "path": path }))).into_response()
}

async fn get_session_attachment(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((session_id, attachment_name)): Path<(String, String)>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (StatusCode::UNAUTHORIZED, Json(json!({ "error": "UNAUTHORIZED" }))).into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    let Some(bytes) = (match state
        .sessions
        .read_image_attachment(&session_id, &attachment_name)
        .await
    {
        Ok(bytes) => bytes,
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": error.to_string() })),
            )
                .into_response();
        }
    }) else {
        return StatusCode::NOT_FOUND.into_response();
    };

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, content_type_for_attachment_name(&attachment_name))],
        bytes,
    )
        .into_response()
}

fn snapshot_to_dto(snapshot: crate::session::model::SessionSnapshot) -> SessionSnapshotDto {
    SessionSnapshotDto {
        id: snapshot.session.id,
        agent_kind: snapshot.session.agent_kind,
        source_kind: snapshot.session.source_kind,
        title: snapshot.session.title,
        runtime_session_id: snapshot.session.runtime_session_id,
        workspace_path: snapshot.session.workspace_path,
        status: snapshot.session.status,
        has_more_history: snapshot.has_more_history,
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

async fn ensure_session_access(
    state: &AppState,
    session_id: &str,
    owner_user_id: &str,
) -> Result<(), axum::response::Response> {
    match state.sessions.can_access_session(session_id, owner_user_id).await {
        Ok(true) => Ok(()),
        Ok(false) => Err((StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response()),
        Err(_) => Err(StatusCode::NOT_FOUND.into_response()),
    }
}

fn current_user_to_dto(user: crate::auth::CurrentUser) -> CurrentUserDto {
    CurrentUserDto {
        id: user.id,
        display_name: user.display_name,
    }
}

fn workspace_root_dtos(state: &AppState) -> Vec<WorkspaceRootDto> {
    workspace::list_roots(&state.config.roots)
        .into_iter()
        .map(|root| WorkspaceRootDto {
            id: root.id,
            label: root.label,
            path: root.path,
        })
        .collect()
}

fn session_summary_to_dto(session: crate::session::model::SessionSummary) -> SessionSummaryDto {
    SessionSummaryDto {
        id: session.id,
        agent_kind: session.agent_kind,
        source_kind: session.source_kind,
        title: session.title,
        runtime_session_id: session.runtime_session_id,
        status: session.status,
        workspace_path: session.workspace_path,
    }
}

fn content_type_for_attachment_name(name: &str) -> &'static str {
    if name.ends_with(".png") {
        "image/png"
    } else if name.ends_with(".jpg") || name.ends_with(".jpeg") {
        "image/jpeg"
    } else if name.ends_with(".gif") {
        "image/gif"
    } else if name.ends_with(".webp") {
        "image/webp"
    } else if name.ends_with(".svg") {
        "image/svg+xml"
    } else {
        "application/octet-stream"
    }
}
