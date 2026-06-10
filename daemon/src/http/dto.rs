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
    pub events: Vec<SessionEventDto>,
}

#[derive(Serialize)]
pub struct SessionSummaryDto {
    pub id: String,
    #[serde(rename = "agentKind")]
    pub agent_kind: String,
    pub status: String,
    #[serde(rename = "workspacePath")]
    pub workspace_path: String,
}
