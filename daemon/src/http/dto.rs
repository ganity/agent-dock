use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct LoginRequest {
    pub pin: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
}

#[derive(Serialize)]
pub struct CurrentUserDto {
    pub id: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
}

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    #[serde(rename = "rootId")]
    pub root_id: String,
    pub path: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    pub title: Option<String>,
}

#[derive(Deserialize)]
pub struct SendMessageRequest {
    pub message: String,
    #[serde(rename = "imagePaths", default)]
    pub image_paths: Vec<String>,
}

#[derive(Deserialize)]
pub struct AttachSessionRequest {
    #[serde(rename = "rootId")]
    pub root_id: String,
    pub path: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    #[serde(rename = "runtimeSessionId")]
    pub runtime_session_id: String,
}

#[derive(Serialize)]
pub struct WorkspaceRootDto {
    pub id: String,
    pub label: String,
    pub path: String,
}

#[derive(Serialize)]
pub struct WorkspaceDirectoryDto {
    pub name: String,
    pub path: String,
}

#[derive(Serialize)]
pub struct WorkspaceDirectoryListingDto {
    #[serde(rename = "currentPath")]
    pub current_path: String,
    #[serde(rename = "parentPath")]
    pub parent_path: Option<String>,
    pub directories: Vec<WorkspaceDirectoryDto>,
}

#[derive(Serialize)]
pub struct SessionEventDto {
    pub id: i64,
    #[serde(rename = "eventType")]
    pub event_type: String,
    pub payload: serde_json::Value,
}

#[derive(Serialize)]
pub struct SessionSnapshotDto {
    pub id: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    #[serde(rename = "sourceKind")]
    pub source_kind: String,
    pub title: Option<String>,
    #[serde(rename = "runtimeSessionId")]
    pub runtime_session_id: Option<String>,
    #[serde(rename = "workspacePath")]
    pub workspace_path: String,
    pub status: String,
    #[serde(rename = "hasMoreHistory")]
    pub has_more_history: bool,
    pub events: Vec<SessionEventDto>,
}

#[derive(Serialize)]
pub struct SessionSummaryDto {
    pub id: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    #[serde(rename = "sourceKind")]
    pub source_kind: String,
    pub title: Option<String>,
    #[serde(rename = "runtimeSessionId")]
    pub runtime_session_id: Option<String>,
    pub status: String,
    #[serde(rename = "workspacePath")]
    pub workspace_path: String,
}
