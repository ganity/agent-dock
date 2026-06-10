use std::sync::Arc;

use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::Child,
};

use crate::{
    adapters::{
        claude::parse_claude_stream_line,
        codex::parse_codex_rpc_line,
        process::{claude_managed_launch, codex_managed_launch, spawn_command, LaunchCommand},
    },
    session::{
        model::{SessionSnapshot, SessionSummary, StoredEvent},
        store::SqliteSessionStore,
    },
};

type ProcessSpawner = Arc<dyn Fn(LaunchCommand) -> anyhow::Result<Child> + Send + Sync>;

#[derive(Clone)]
pub struct SessionService {
    store: Arc<SqliteSessionStore>,
    process_spawner: ProcessSpawner,
}

impl SessionService {
    pub fn new(store: SqliteSessionStore) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner: Arc::new(spawn_command),
        }
    }

    pub fn new_with_spawner(store: SqliteSessionStore, process_spawner: ProcessSpawner) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner,
        }
    }

    pub async fn create_managed_session(
        &self,
        root_id: String,
        workspace_path: String,
        agent_kind: String,
    ) -> anyhow::Result<String> {
        let session_id = self
            .store
            .create_session(root_id, workspace_path, "managed".into(), agent_kind.clone())
            .await?;
        self.store
            .append_event(&session_id, "session.created", r#"{"status":"created"}"#)
            .await?;

        match agent_kind.as_str() {
            "claude" => {
                self.spawn_managed_runtime(&session_id, claude_managed_launch(), parse_claude_stream_line)
                    .await?;
            }
            "codex" => {
                self.spawn_managed_runtime(&session_id, codex_managed_launch(), parse_codex_rpc_line)
                    .await?;
            }
            _ => {}
        }

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

    async fn spawn_managed_runtime(
        &self,
        session_id: &str,
        launch_command: LaunchCommand,
        parser: fn(&str) -> anyhow::Result<Option<StoredEvent>>,
    ) -> anyhow::Result<()> {
        self.store.update_session_status(session_id, "running").await?;
        self.store
            .append_event(session_id, "session.status.changed", r#"{"status":"running"}"#)
            .await?;

        let mut child = (self.process_spawner)(launch_command)?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("managed session missing stdout"))?;
        let store = self.store.clone();
        let session_id = session_id.to_string();

        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();

            while let Ok(Some(line)) = lines.next_line().await {
                match parser(&line) {
                    Ok(Some(event)) => {
                        let _ = store
                            .append_event(&session_id, &event.event_type, &event.payload_json)
                            .await;
                    }
                    Ok(None) => {}
                    Err(_) => {}
                }
            }

            let _ = child.wait().await;
            let _ = store.update_session_status(&session_id, "completed").await;
            let _ = store
                .append_event(&session_id, "session.status.changed", r#"{"status":"completed"}"#)
                .await;
        });

        Ok(())
    }
}
