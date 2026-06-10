#[derive(Clone, Debug, PartialEq)]
pub struct SessionRecord {
    pub id: String,
    pub root_id: String,
    pub workspace_path: String,
    pub source_kind: String,
    pub agent_kind: String,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StoredEvent {
    pub id: i64,
    pub event_type: String,
    pub payload_json: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionSummary {
    pub id: String,
    pub workspace_path: String,
    pub source_kind: String,
    pub agent_kind: String,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionSnapshot {
    pub session: SessionRecord,
    pub events: Vec<StoredEvent>,
}
