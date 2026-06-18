#[derive(Clone, Debug, PartialEq)]
pub struct SessionRecord {
    pub id: String,
    pub owner_user_id: String,
    pub root_id: String,
    pub workspace_path: String,
    pub source_kind: String,
    pub agent_kind: String,
    pub title: Option<String>,
    pub runtime_session_id: Option<String>,
    pub status: String,
    pub runtime_health: String,
    pub runtime_error_kind: Option<String>,
    pub runtime_error_message: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StoredEvent {
    pub id: i64,
    pub event_type: String,
    pub payload_json: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PendingUserMessage {
    pub id: i64,
    pub text: String,
    pub image_paths: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionSummary {
    pub id: String,
    pub owner_user_id: String,
    pub workspace_path: String,
    pub source_kind: String,
    pub agent_kind: String,
    pub title: Option<String>,
    pub runtime_session_id: Option<String>,
    pub status: String,
    pub runtime_health: String,
    pub runtime_error_kind: Option<String>,
    pub runtime_error_message: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionSnapshot {
    pub session: SessionRecord,
    pub events: Vec<StoredEvent>,
    pub has_more_history: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ResumeCandidate {
    pub runtime_session_id: String,
    pub title: Option<String>,
    pub agent_kind: String,
    pub workspace_path: String,
    pub updated_at: Option<String>,
    pub status: Option<String>,
}
