use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
pub struct LoginRequest {
    pub pin: String,
}

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    #[serde(rename = "rootId")]
    pub root_id: String,
    pub path: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
}

#[derive(Deserialize)]
pub struct SendMessageRequest {
    pub message: String,
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
    #[serde(rename = "runtimeSessionId")]
    pub runtime_session_id: Option<String>,
    #[serde(rename = "workspacePath")]
    pub workspace_path: String,
    pub status: String,
    pub events: Vec<SessionEventDto>,
}

#[derive(Serialize)]
pub struct SessionSummaryDto {
    pub id: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    #[serde(rename = "sourceKind")]
    pub source_kind: String,
    #[serde(rename = "runtimeSessionId")]
    pub runtime_session_id: Option<String>,
    pub status: String,
    #[serde(rename = "workspacePath")]
    pub workspace_path: String,
}
