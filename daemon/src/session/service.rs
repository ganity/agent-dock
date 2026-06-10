use std::sync::Arc;

use crate::session::{
    model::{SessionSnapshot, SessionSummary, StoredEvent},
    store::SqliteSessionStore,
};

#[derive(Clone)]
pub struct SessionService {
    store: Arc<SqliteSessionStore>,
}

impl SessionService {
    pub fn new(store: SqliteSessionStore) -> Self {
        Self {
            store: Arc::new(store),
        }
    }

    pub async fn create_placeholder_session(
        &self,
        root_id: String,
        workspace_path: String,
        agent_kind: String,
    ) -> anyhow::Result<String> {
        let session_id = self
            .store
            .create_session(root_id, workspace_path, "managed".into(), agent_kind)
            .await?;
        self.store
            .append_event(&session_id, "session.created", r#"{"status":"created"}"#)
            .await?;
        Ok(session_id)
    }

    pub async fn load_snapshot(&self, session_id: &str) -> anyhow::Result<SessionSnapshot> {
        self.store.load_snapshot(session_id).await
    }

    pub async fn list_sessions(&self) -> anyhow::Result<Vec<SessionSummary>> {
        self.store.list_sessions().await
    }

    pub async fn events_after(&self, session_id: &str, cursor: i64) -> anyhow::Result<Vec<StoredEvent>> {
        self.store.events_after(session_id, cursor).await
    }
}
