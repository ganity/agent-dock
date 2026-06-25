use axum::{
    Json, Router,
    body::Bytes,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode, header},
    response::IntoResponse,
    routing::{get, post},
};
use serde_json::json;
use std::collections::HashMap;

use crate::{
    app::AppState,
    http::dto::{
        AdminUserDto, AttachSessionRequest, CreateSessionRequest, CreateUserRequest,
        CurrentUserDto, LoginRequest, ResetUserPasswordRequest, ResumeCandidateDto,
        SendMessageAckDto, SendMessageRequest, SessionEventDto, SessionSnapshotDto,
        SessionSummaryDto, WorkspaceDirectoryDto, WorkspaceDirectoryListingDto, WorkspaceEntryDto,
        WorkspaceEntryListingDto, WorkspaceFileDto, WorkspaceRootDto,
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
        .route("/api/admin/users", get(list_users).post(create_user))
        .route("/api/admin/users/{id}/password", post(reset_user_password))
        .route("/api/admin/users/{id}", axum::routing::delete(delete_user))
        .route("/api/workspaces/roots", get(workspace_roots))
        .route("/api/workspaces/directories", get(workspace_directories))
        .route("/api/sessions", post(create_session).get(list_sessions))
        .route(
            "/api/sessions/resume-candidates",
            get(list_resume_candidates),
        )
        .route("/api/sessions/attach", post(attach_session))
        .route(
            "/api/sessions/{id}",
            get(get_session).delete(delete_session),
        )
        .route("/api/sessions/{id}/resume", post(resume_session))
        .route(
            "/api/sessions/{id}/workspace/entries",
            get(list_session_workspace_entries),
        )
        .route(
            "/api/sessions/{id}/workspace/file",
            get(get_session_workspace_file),
        )
        .route(
            "/api/sessions/{id}/attachments/{name}",
            get(get_session_attachment),
        )
        .route(
            "/api/sessions/{id}/attachments",
            post(upload_session_attachment),
        )
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
    let token = match (&request.username, &request.password) {
        (Some(username), Some(password)) => state.auth.login_user(username, password).await,
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
        None => (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "INVALID_CREDENTIALS" })),
        )
            .into_response(),
    }
}

async fn auth_session(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    (
        StatusCode::OK,
        Json(json!({ "ok": true, "user": current_user_to_dto(user) })),
    )
        .into_response()
}

async fn mobile_bootstrap(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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

async fn workspace_roots(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    }

    let roots = workspace_root_dtos(&state);

    (StatusCode::OK, Json(json!({ "roots": roots }))).into_response()
}

async fn list_users(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };
    if !user.is_admin {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response();
    }

    match state.auth.list_users().await {
        Ok(users) => (
            StatusCode::OK,
            Json(json!({
                "users": users.into_iter().map(admin_user_to_dto).collect::<Vec<_>>(),
            })),
        )
            .into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": error.to_string() })),
        )
            .into_response(),
    }
}

async fn create_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<CreateUserRequest>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };
    if !user.is_admin {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response();
    }

    let username = request.username.trim();
    let password = request.password.trim();
    if username.is_empty() || password.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "INVALID_INPUT" })),
        )
            .into_response();
    }

    match state
        .auth
        .create_user(username, password, request.is_admin)
        .await
    {
        Ok(created) => (
            StatusCode::CREATED,
            Json(json!({ "user": admin_user_to_dto(created) })),
        )
            .into_response(),
        Err(crate::auth::CreateUserError::UsernameTaken) => (
            StatusCode::CONFLICT,
            Json(json!({ "error": "USERNAME_TAKEN" })),
        )
            .into_response(),
        Err(crate::auth::CreateUserError::InvalidInput) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "INVALID_INPUT" })),
        )
            .into_response(),
        Err(crate::auth::CreateUserError::Unexpected(error)) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": error.to_string() })),
        )
            .into_response(),
    }
}

async fn reset_user_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Json(request): Json<ResetUserPasswordRequest>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };
    if !user.is_admin {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response();
    }

    if request.password.trim().is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "INVALID_INPUT" })),
        )
            .into_response();
    }

    match state
        .auth
        .reset_password(&user_id, request.password.trim())
        .await
    {
        Ok(true) => (StatusCode::OK, Json(json!({ "ok": true }))).into_response(),
        Ok(false) => (StatusCode::NOT_FOUND, Json(json!({ "error": "NOT_FOUND" }))).into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": error.to_string() })),
        )
            .into_response(),
    }
}

async fn delete_user(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };
    if !user.is_admin {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response();
    }

    match state.auth.delete_user(&user_id).await {
        Ok(crate::auth::DeleteUserResult::Deleted) => StatusCode::NO_CONTENT.into_response(),
        Ok(crate::auth::DeleteUserResult::NotFound) => {
            (StatusCode::NOT_FOUND, Json(json!({ "error": "NOT_FOUND" }))).into_response()
        }
        Ok(crate::auth::DeleteUserResult::LastAdmin) => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "LAST_ADMIN_REQUIRED" })),
        )
            .into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": error.to_string() })),
        )
            .into_response(),
    }
}

async fn workspace_directories(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    if !is_authenticated(&state, &headers) {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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

async fn list_sessions(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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

    let response = sessions
        .into_iter()
        .map(session_summary_to_dto)
        .collect::<Vec<_>>();

    (StatusCode::OK, Json(json!({ "sessions": response }))).into_response()
}

async fn list_resume_candidates(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let Some(_user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    let Some(root_id) = query.get("rootId").map(String::as_str) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "rootId query parameter is required" })),
        )
            .into_response();
    };
    let Some(agent_kind) = query.get("agentKind").map(String::as_str) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "agentKind query parameter is required" })),
        )
            .into_response();
    };
    let Some(path) = query.get("path").map(String::as_str) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "path query parameter is required" })),
        )
            .into_response();
    };

    let Some(root) = state.config.roots.iter().find(|root| root.id == root_id) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "UNKNOWN_ROOT" })),
        )
            .into_response();
    };

    let workspace_path = normalize_workspace_path(&root.path, path);
    let candidates = match state
        .sessions
        .list_resume_candidates(agent_kind, &workspace_path)
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

    let response = candidates
        .into_iter()
        .map(|candidate| ResumeCandidateDto {
            runtime_session_id: candidate.runtime_session_id,
            title: candidate.title,
            agent_kind: candidate.agent_kind,
            workspace_path: candidate.workspace_path,
            updated_at: candidate.updated_at,
            status: candidate.status,
        })
        .collect::<Vec<_>>();

    (StatusCode::OK, Json(json!({ "candidates": response }))).into_response()
}

async fn attach_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<AttachSessionRequest>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    let limit = query
        .get("limit")
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0);
    let before = query
        .get("before")
        .and_then(|value| value.parse::<i64>().ok());

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    let snapshot = match state
        .sessions
        .load_snapshot_window(&session_id, limit, before)
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

    (StatusCode::OK, Json(snapshot_to_dto(snapshot))).into_response()
}

async fn delete_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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

async fn resume_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    match state.sessions.resume_session(&session_id).await {
        Ok(snapshot) => (StatusCode::OK, Json(snapshot_to_dto(snapshot))).into_response(),
        Err(error) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": error.to_string() })),
        )
            .into_response(),
    }
}

async fn list_session_workspace_entries(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    let path = query.get("path").map(String::as_str).unwrap_or(".");
    let snapshot = match state.sessions.load_snapshot(&session_id).await {
        Ok(value) => value,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let Some(workspace_path) = session_workspace_filesystem_path(&state, &snapshot.session) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "UNKNOWN_ROOT" })),
        )
            .into_response();
    };
    let listing = match workspace::list_workspace_entries(&workspace_path, path) {
        Ok(value) => value,
        Err(error) => return workspace_file_error_response(error),
    };

    let response = WorkspaceEntryListingDto {
        current_path: listing.current_path,
        parent_path: listing.parent_path,
        entries: listing
            .entries
            .into_iter()
            .map(|entry| WorkspaceEntryDto {
                name: entry.name,
                path: entry.path,
                kind: match entry.kind {
                    workspace::WorkspaceEntryKind::Directory => "directory".into(),
                    workspace::WorkspaceEntryKind::File => "file".into(),
                },
            })
            .collect(),
    };

    (StatusCode::OK, Json(response)).into_response()
}

async fn get_session_workspace_file(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    let Some(path) = query.get("path").map(String::as_str) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "path query parameter is required" })),
        )
            .into_response();
    };

    let snapshot = match state.sessions.load_snapshot(&session_id).await {
        Ok(value) => value,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let Some(workspace_path) = session_workspace_filesystem_path(&state, &snapshot.session) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "UNKNOWN_ROOT" })),
        )
            .into_response();
    };
    let file = match workspace::read_workspace_text_file(&workspace_path, path) {
        Ok(value) => value,
        Err(error) => return workspace_file_error_response(error),
    };

    let response = WorkspaceFileDto {
        name: file.name,
        path: file.path,
        content: file.content,
        render_mode: match file.render_mode {
            workspace::WorkspaceFileRenderMode::Markdown => "markdown".into(),
            workspace::WorkspaceFileRenderMode::Text => "text".into(),
        },
    };

    (StatusCode::OK, Json(response)).into_response()
}

async fn send_session_message(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(session_id): Path<String>,
    Json(request): Json<SendMessageRequest>,
) -> impl IntoResponse {
    let Some(user) = current_user_from_headers(&state, &headers) else {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
    };

    if let Err(response) = ensure_session_access(&state, &session_id, &user.id).await {
        return response;
    }

    if let Some(client_message_id) = request.client_message_id.as_deref() {
        match state
            .sessions
            .message_receipt_event_id(&session_id, client_message_id)
            .await
        {
            Ok(Some(event_id)) => {
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

                return (
                    StatusCode::OK,
                    Json(SendMessageAckDto {
                        accepted: true,
                        client_message_id: request.client_message_id,
                        event_id,
                        session_status: snapshot.session.status,
                    }),
                )
                    .into_response();
            }
            Ok(None) => {}
            Err(error) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(json!({ "error": error.to_string() })),
                )
                    .into_response();
            }
        }
    }

    match state
        .sessions
        .send_user_message_with_images(
            &session_id,
            request.client_message_id.as_deref(),
            request.message,
            request.image_paths,
        )
        .await
    {
        Ok(user_message_event_id) => {
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
            (
                StatusCode::OK,
                Json(SendMessageAckDto {
                    accepted: true,
                    client_message_id: request.client_message_id,
                    event_id: user_message_event_id,
                    session_status: snapshot.session.status,
                }),
            )
                .into_response()
        }
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
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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
    let path = match state
        .sessions
        .store_image_attachment(&session_id, filename, &body)
        .await
    {
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
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({ "error": "UNAUTHORIZED" })),
        )
            .into_response();
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
        [(
            header::CONTENT_TYPE,
            content_type_for_attachment_name(&attachment_name),
        )],
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
        runtime_health: snapshot.session.runtime_health,
        runtime_error_kind: snapshot.session.runtime_error_kind,
        runtime_error_message: snapshot.session.runtime_error_message,
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
    match state
        .sessions
        .can_access_session(session_id, owner_user_id)
        .await
    {
        Ok(true) => Ok(()),
        Ok(false) => {
            Err((StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response())
        }
        Err(_) => Err(StatusCode::NOT_FOUND.into_response()),
    }
}

fn workspace_file_error_response(error: workspace::WorkspaceFileError) -> axum::response::Response {
    match error {
        workspace::WorkspaceFileError::Forbidden => {
            (StatusCode::FORBIDDEN, Json(json!({ "error": "FORBIDDEN" }))).into_response()
        }
        workspace::WorkspaceFileError::NotFound => {
            (StatusCode::NOT_FOUND, Json(json!({ "error": "NOT_FOUND" }))).into_response()
        }
        workspace::WorkspaceFileError::TooLarge => (
            StatusCode::PAYLOAD_TOO_LARGE,
            Json(json!({ "error": "FILE_TOO_LARGE" })),
        )
            .into_response(),
        workspace::WorkspaceFileError::InvalidUtf8 => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "FILE_NOT_TEXT" })),
        )
            .into_response(),
        workspace::WorkspaceFileError::NotDirectory => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "PATH_NOT_DIRECTORY" })),
        )
            .into_response(),
        workspace::WorkspaceFileError::NotFile => (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "PATH_NOT_FILE" })),
        )
            .into_response(),
        workspace::WorkspaceFileError::Io(message) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": message })),
        )
            .into_response(),
    }
}

fn current_user_to_dto(user: crate::auth::CurrentUser) -> CurrentUserDto {
    CurrentUserDto {
        id: user.id,
        display_name: user.display_name,
        is_admin: user.is_admin,
    }
}

fn admin_user_to_dto(user: crate::user::store::StoredUser) -> AdminUserDto {
    AdminUserDto {
        id: user.id,
        username: user.username.clone(),
        display_name: {
            let mut chars = user.username.chars();
            match chars.next() {
                Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str()),
                None => "User".into(),
            }
        },
        is_admin: user.is_admin,
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
        runtime_health: session.runtime_health,
        runtime_error_kind: session.runtime_error_kind,
        runtime_error_message: session.runtime_error_message,
    }
}

fn session_workspace_filesystem_path(
    state: &AppState,
    session: &crate::session::model::SessionRecord,
) -> Option<String> {
    if std::path::Path::new(&session.workspace_path).is_absolute() {
        return Some(session.workspace_path.clone());
    }

    let root = state
        .config
        .roots
        .iter()
        .find(|root| root.id == session.root_id)?;
    Some(normalize_workspace_path(
        &root.path,
        &session.workspace_path,
    ))
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

fn normalize_workspace_path(root_path: &str, path: &str) -> String {
    let candidate = std::path::Path::new(path);
    if candidate.is_absolute() {
        return candidate.to_string_lossy().into_owned();
    }

    std::path::Path::new(root_path)
        .join(candidate)
        .to_string_lossy()
        .into_owned()
}
