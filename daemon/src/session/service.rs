use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Child,
    sync::mpsc,
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
    runtime_inputs: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<String>>>>,
}

impl SessionService {
    pub fn new(store: SqliteSessionStore) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner: Arc::new(spawn_command),
            runtime_inputs: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn new_with_spawner(store: SqliteSessionStore, process_spawner: ProcessSpawner) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner,
            runtime_inputs: Arc::new(Mutex::new(HashMap::new())),
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

    pub async fn send_user_message(&self, session_id: &str, message: String) -> anyhow::Result<()> {
        let snapshot = self.store.load_snapshot(session_id).await?;
        self.store
            .append_event(
                session_id,
                "user.message",
                &serde_json::json!({ "text": message }).to_string(),
            )
            .await?;

        let Some(sender) = self.runtime_inputs.lock().unwrap().get(session_id).cloned() else {
            return Ok(());
        };

        let payload = encode_runtime_input(&snapshot.session.agent_kind, &message);
        sender
            .send(payload)
            .map_err(|_| anyhow::anyhow!("managed runtime input channel closed"))?;

        Ok(())
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
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("managed session missing stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("managed session missing stdout"))?;
        let store = self.store.clone();
        let session_id = session_id.to_string();
        let runtime_inputs = self.runtime_inputs.clone();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();

        runtime_inputs
            .lock()
            .unwrap()
            .insert(session_id.clone(), tx);

        tokio::spawn(async move {
            let mut stdin = stdin;
            let writer = tokio::spawn(async move {
                while let Some(message) = rx.recv().await {
                    if stdin.write_all(message.as_bytes()).await.is_err() {
                        break;
                    }
                    if stdin.flush().await.is_err() {
                        break;
                    }
                }
            });

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

            let _ = writer.await;
            let _ = child.wait().await;
            runtime_inputs.lock().unwrap().remove(&session_id);
            let _ = store.update_session_status(&session_id, "completed").await;
            let _ = store
                .append_event(&session_id, "session.status.changed", r#"{"status":"completed"}"#)
                .await;
        });

        Ok(())
    }
}

fn encode_runtime_input(agent_kind: &str, message: &str) -> String {
    match agent_kind {
        "claude" => serde_json::json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": message,
            }
        })
        .to_string()
            + "\n",
        "codex" => serde_json::json!({
            "jsonrpc": "2.0",
            "id": "agent-workspace",
            "method": "session/userMessage",
            "params": {
                "text": message,
            }
        })
        .to_string()
            + "\n",
        _ => format!("{message}\n"),
    }
}
