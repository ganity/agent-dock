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
        claude::{parse_claude_result_session_id, parse_claude_stream_line},
        codex_protocol::CodexSessionProtocol,
        process::{claude_turn_launch, codex_managed_launch, spawn_command, LaunchCommand},
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
    codex_protocols: Arc<Mutex<HashMap<String, CodexSessionProtocol>>>,
}

impl SessionService {
    pub fn new(store: SqliteSessionStore) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner: Arc::new(spawn_command),
            runtime_inputs: Arc::new(Mutex::new(HashMap::new())),
            codex_protocols: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn new_with_spawner(store: SqliteSessionStore, process_spawner: ProcessSpawner) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner,
            runtime_inputs: Arc::new(Mutex::new(HashMap::new())),
            codex_protocols: Arc::new(Mutex::new(HashMap::new())),
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
            .create_session(root_id, workspace_path.clone(), "managed".into(), agent_kind.clone())
            .await?;
        self.store
            .append_event(&session_id, "session.created", r#"{"status":"created"}"#)
            .await?;

        match agent_kind.as_str() {
            "claude" => {}
            "codex" => {
                self.spawn_codex_runtime(&session_id, &workspace_path)
                    .await?;
            }
            _ => {}
        }

        Ok(session_id)
    }

    pub async fn attach_existing_session(
        &self,
        root_id: String,
        workspace_path: String,
        agent_kind: String,
        runtime_session_id: String,
    ) -> anyhow::Result<String> {
        let session_id = self
            .store
            .create_session(root_id, workspace_path, "attached".into(), agent_kind)
            .await?;
        self.store
            .update_runtime_session_id(&session_id, &runtime_session_id)
            .await?;
        self.store
            .append_event(
                &session_id,
                "session.attached",
                &serde_json::json!({ "runtimeSessionId": runtime_session_id }).to_string(),
            )
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

    pub async fn send_user_message(&self, session_id: &str, message: String) -> anyhow::Result<()> {
        let snapshot = self.store.load_snapshot(session_id).await?;
        self.store
            .append_event(
                session_id,
                "user.message",
                &serde_json::json!({ "text": message }).to_string(),
            )
            .await?;

        if snapshot.session.agent_kind == "claude" {
            self.spawn_claude_turn(
                session_id,
                message,
                snapshot.session.runtime_session_id.clone(),
            )
            .await?;
            return Ok(());
        }

        let Some(sender) = self.runtime_inputs.lock().unwrap().get(session_id).cloned() else {
            return Ok(());
        };

        if snapshot.session.agent_kind == "codex" {
            let outgoing = {
                let mut protocols = self.codex_protocols.lock().unwrap();
                let Some(protocol) = protocols.get_mut(session_id) else {
                    return Ok(());
                };
                protocol.enqueue_user_message(message)?
            };

            for request in outgoing {
                sender
                    .send(encode_json_line(request))
                    .map_err(|_| anyhow::anyhow!("managed runtime input channel closed"))?;
            }
        } else {
            let payload = encode_runtime_input(&snapshot.session.agent_kind, &message);
            sender
                .send(payload)
                .map_err(|_| anyhow::anyhow!("managed runtime input channel closed"))?;
        }

        Ok(())
    }

    async fn spawn_claude_turn(
        &self,
        session_id: &str,
        message: String,
        runtime_session_id: Option<String>,
    ) -> anyhow::Result<()> {
        self.store.update_session_status(session_id, "running").await?;
        self.store
            .append_event(session_id, "session.status.changed", r#"{"status":"running"}"#)
            .await?;

        let launch_command = claude_turn_launch(&message, runtime_session_id.as_deref());
        let mut child = (self.process_spawner)(launch_command)?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("managed session missing stdout"))?;
        let store = self.store.clone();
        let session_id = session_id.to_string();
        let runtime_session_id_store = self.store.clone();

        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();

            while let Ok(Some(line)) = lines.next_line().await {
                if let Ok(Some(runtime_session_id)) = parse_claude_result_session_id(&line) {
                    let _ = runtime_session_id_store
                        .update_runtime_session_id(&session_id, &runtime_session_id)
                        .await;
                }

                match parse_claude_stream_line(&line) {
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

    async fn spawn_codex_runtime(
        &self,
        session_id: &str,
        workspace_path: &str,
    ) -> anyhow::Result<()> {
        self.store.update_session_status(session_id, "running").await?;
        self.store
            .append_event(session_id, "session.status.changed", r#"{"status":"running"}"#)
            .await?;

        let mut child = (self.process_spawner)(codex_managed_launch())?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| anyhow::anyhow!("managed codex session missing stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| anyhow::anyhow!("managed codex session missing stdout"))?;
        let store = self.store.clone();
        let session_id = session_id.to_string();
        let runtime_inputs = self.runtime_inputs.clone();
        let codex_protocols = self.codex_protocols.clone();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();

        let mut protocol = CodexSessionProtocol::new(workspace_path.to_string());
        let bootstrap = protocol.bootstrap_requests();
        codex_protocols
            .lock()
            .unwrap()
            .insert(session_id.clone(), protocol);
        runtime_inputs
            .lock()
            .unwrap()
            .insert(session_id.clone(), tx.clone());

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

            for request in bootstrap {
                let _ = tx.send(encode_json_line(request));
            }

            let mut lines = BufReader::new(stdout).lines();

            while let Ok(Some(line)) = lines.next_line().await {
                let result = {
                    let mut protocols = codex_protocols.lock().unwrap();
                    protocols
                        .get_mut(&session_id)
                        .map(|protocol| protocol.handle_server_line(&line))
                };

                let Some(result) = result else {
                    continue;
                };

                match result {
                    Ok(result) => {
                        for request in result.outgoing {
                            let _ = tx.send(encode_json_line(request));
                        }
                        if let Some(event) = result.event {
                            let _ = store
                                .append_event(&session_id, &event.event_type, &event.payload_json)
                                .await;
                        }
                    }
                    Err(_) => {}
                }
            }

            let _ = writer.await;
            let _ = child.wait().await;
            runtime_inputs.lock().unwrap().remove(&session_id);
            codex_protocols.lock().unwrap().remove(&session_id);
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
        _ => format!("{message}\n"),
    }
}

fn encode_json_line(value: serde_json::Value) -> String {
    value.to_string() + "\n"
}
