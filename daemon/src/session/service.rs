use std::{
    collections::HashMap,
    path::PathBuf,
    process::ExitStatus,
    sync::{Arc, Mutex},
};

use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Child,
    sync::{Mutex as TokioMutex, mpsc},
};

use crate::{
    adapters::{
        claude::{parse_claude_result_session_id, parse_claude_stream_line},
        codex_protocol::{CodexSessionProtocol, UserMessage},
        process::{LaunchCommand, claude_turn_launch, codex_managed_launch, spawn_command},
        resume::{list_claude_resume_candidates, list_codex_resume_candidates},
    },
    session::{
        model::{ResumeCandidate, SessionSnapshot, SessionSummary, StoredEvent},
        store::SqliteSessionStore,
    },
};

type ProcessSpawner = Arc<dyn Fn(LaunchCommand) -> anyhow::Result<Child> + Send + Sync>;
type RuntimeChild = Arc<TokioMutex<Option<Child>>>;

#[derive(Clone)]
pub struct SessionService {
    store: Arc<SqliteSessionStore>,
    process_spawner: ProcessSpawner,
    attachment_root: Arc<PathBuf>,
    claude_projects_root: Arc<Option<PathBuf>>,
    runtime_inputs: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<String>>>>,
    codex_protocols: Arc<Mutex<HashMap<String, CodexSessionProtocol>>>,
    runtime_children: Arc<Mutex<HashMap<String, RuntimeChild>>>,
}

impl SessionService {
    pub fn new(store: SqliteSessionStore) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner: Arc::new(spawn_command),
            attachment_root: Arc::new(PathBuf::from("./daemon-data/attachments")),
            claude_projects_root: Arc::new(None),
            runtime_inputs: Arc::new(Mutex::new(HashMap::new())),
            codex_protocols: Arc::new(Mutex::new(HashMap::new())),
            runtime_children: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn new_with_spawner(store: SqliteSessionStore, process_spawner: ProcessSpawner) -> Self {
        Self {
            store: Arc::new(store),
            process_spawner,
            attachment_root: Arc::new(PathBuf::from("./daemon-data/attachments")),
            claude_projects_root: Arc::new(None),
            runtime_inputs: Arc::new(Mutex::new(HashMap::new())),
            codex_protocols: Arc::new(Mutex::new(HashMap::new())),
            runtime_children: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn with_attachment_root(mut self, attachment_root: PathBuf) -> Self {
        self.attachment_root = Arc::new(attachment_root);
        self
    }

    pub fn with_claude_projects_root(mut self, claude_projects_root: Option<PathBuf>) -> Self {
        self.claude_projects_root = Arc::new(claude_projects_root);
        self
    }

    pub async fn create_managed_session(
        &self,
        root_id: String,
        workspace_path: String,
        agent_kind: String,
        title: Option<String>,
    ) -> anyhow::Result<String> {
        self.create_managed_session_for_user(
            "usr_workspace".into(),
            root_id,
            workspace_path,
            agent_kind,
            title,
        )
        .await
    }

    pub async fn create_managed_session_for_user(
        &self,
        owner_user_id: String,
        root_id: String,
        workspace_path: String,
        agent_kind: String,
        title: Option<String>,
    ) -> anyhow::Result<String> {
        let session_id = self
            .store
            .create_session(
                owner_user_id,
                root_id,
                workspace_path.clone(),
                "managed".into(),
                agent_kind.clone(),
                title,
            )
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
        self.attach_existing_session_for_user(
            "usr_workspace".into(),
            root_id,
            workspace_path,
            agent_kind,
            runtime_session_id,
        )
        .await
    }

    pub async fn attach_existing_session_for_user(
        &self,
        owner_user_id: String,
        root_id: String,
        workspace_path: String,
        agent_kind: String,
        runtime_session_id: String,
    ) -> anyhow::Result<String> {
        let session_id = self
            .store
            .create_session(
                owner_user_id,
                root_id,
                workspace_path,
                "attached".into(),
                agent_kind,
                None,
            )
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

    pub async fn load_snapshot_window(
        &self,
        session_id: &str,
        limit: Option<usize>,
        before: Option<i64>,
    ) -> anyhow::Result<SessionSnapshot> {
        self.store
            .load_snapshot_window(session_id, limit, before)
            .await
    }

    pub async fn list_sessions(&self) -> anyhow::Result<Vec<SessionSummary>> {
        self.list_sessions_for_user("usr_workspace").await
    }

    pub async fn list_sessions_for_user(
        &self,
        owner_user_id: &str,
    ) -> anyhow::Result<Vec<SessionSummary>> {
        self.store.list_sessions(owner_user_id).await
    }

    pub async fn can_access_session(
        &self,
        session_id: &str,
        owner_user_id: &str,
    ) -> anyhow::Result<bool> {
        let snapshot = self.store.load_snapshot(session_id).await?;
        Ok(snapshot.session.owner_user_id == owner_user_id)
    }

    pub async fn list_resume_candidates(
        &self,
        agent_kind: &str,
        workspace_path: &str,
    ) -> anyhow::Result<Vec<ResumeCandidate>> {
        match agent_kind {
            "codex" => list_codex_resume_candidates(workspace_path, &*self.process_spawner).await,
            "claude" => {
                list_claude_resume_candidates(
                    workspace_path,
                    self.claude_projects_root
                        .as_ref()
                        .as_ref()
                        .map(PathBuf::as_path),
                )
                .await
            }
            _ => Ok(Vec::new()),
        }
    }

    pub async fn delete_session(&self, session_id: &str) -> anyhow::Result<bool> {
        let sender = self.runtime_inputs.lock().unwrap().remove(session_id);
        drop(sender);
        self.codex_protocols.lock().unwrap().remove(session_id);

        let child_handle = self.runtime_children.lock().unwrap().remove(session_id);
        if let Some(child_handle) = child_handle {
            let mut child = child_handle.lock().await;
            if let Some(mut child) = child.take() {
                let _ = child.start_kill();
                let _ = child.wait().await;
            }
        }

        let deleted = self.store.delete_session(session_id).await?;
        if deleted {
            let mut attachment_directory = (*self.attachment_root).clone();
            attachment_directory.push(session_id);
            match tokio::fs::remove_dir_all(attachment_directory).await {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }

        Ok(deleted)
    }

    pub async fn events_after(
        &self,
        session_id: &str,
        cursor: i64,
    ) -> anyhow::Result<Vec<StoredEvent>> {
        self.store.events_after(session_id, cursor).await
    }

    pub async fn latest_event_id(&self, session_id: &str) -> anyhow::Result<Option<i64>> {
        self.store.latest_event_id(session_id).await
    }

    pub async fn message_receipt_event_id(
        &self,
        session_id: &str,
        client_message_id: &str,
    ) -> anyhow::Result<Option<i64>> {
        self.store
            .message_receipt_event_id(session_id, client_message_id)
            .await
    }

    pub async fn record_message_receipt(
        &self,
        session_id: &str,
        client_message_id: &str,
        event_id: i64,
    ) -> anyhow::Result<()> {
        self.store
            .record_message_receipt(session_id, client_message_id, event_id)
            .await
    }

    pub async fn resume_session(&self, session_id: &str) -> anyhow::Result<SessionSnapshot> {
        let snapshot = self.store.load_snapshot(session_id).await?;

        if snapshot.session.agent_kind == "codex"
            && self
                .runtime_inputs
                .lock()
                .unwrap()
                .get(session_id)
                .is_none()
        {
            self.store.reset_in_flight_user_messages(session_id).await?;
            let resume_thread_id = snapshot
                .session
                .runtime_session_id
                .clone()
                .or_else(|| find_latest_codex_thread_id(&snapshot.events));

            if let Some(thread_id) = resume_thread_id {
                if snapshot.session.runtime_session_id.as_deref() != Some(thread_id.as_str()) {
                    self.store
                        .update_runtime_session_id(session_id, &thread_id)
                        .await?;
                }

                self.spawn_attached_codex_runtime(
                    session_id,
                    &snapshot.session.workspace_path,
                    thread_id,
                )
                .await?;
            } else if snapshot.session.source_kind == "managed" {
                self.spawn_codex_runtime(session_id, &snapshot.session.workspace_path)
                    .await?;
            }
        }

        self.drain_codex_pending_messages(session_id).await?;

        self.store
            .load_snapshot_window(session_id, Some(50), None)
            .await
    }

    pub async fn store_image_attachment(
        &self,
        session_id: &str,
        filename: &str,
        bytes: &[u8],
    ) -> anyhow::Result<String> {
        let safe_filename = sanitize_attachment_filename(filename);
        let mut directory = (*self.attachment_root).clone();
        directory.push(session_id);
        tokio::fs::create_dir_all(&directory).await?;

        let mut path = directory;
        path.push(format!("{}-{safe_filename}", uuid::Uuid::new_v4()));
        tokio::fs::write(&path, bytes).await?;

        let absolute = tokio::fs::canonicalize(path).await?;
        Ok(absolute.to_string_lossy().into_owned())
    }

    pub async fn read_image_attachment(
        &self,
        session_id: &str,
        attachment_name: &str,
    ) -> anyhow::Result<Option<Vec<u8>>> {
        let mut path = (*self.attachment_root).clone();
        path.push(session_id);
        path.push(sanitize_attachment_filename(attachment_name));

        match tokio::fs::read(path).await {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    pub async fn send_user_message(
        &self,
        session_id: &str,
        message: String,
    ) -> anyhow::Result<i64> {
        self.send_user_message_with_images(session_id, None, message, Vec::new())
            .await
    }

    pub async fn send_user_message_with_images(
        &self,
        session_id: &str,
        client_message_id: Option<&str>,
        message: String,
        image_paths: Vec<String>,
    ) -> anyhow::Result<i64> {
        let snapshot = self.store.load_snapshot(session_id).await?;

        if snapshot.session.agent_kind == "claude" {
            let event_id = self
                .store
                .append_user_message_event(session_id, client_message_id, &message, &image_paths)
                .await?;
            let message = format_message_for_claude(message, &image_paths);
            self.spawn_claude_turn(
                session_id,
                message,
                snapshot.session.runtime_session_id.clone(),
            )
            .await?;
            return Ok(event_id);
        }

        if snapshot.session.agent_kind == "codex" {
            let (event_id, _) = self
                .store
                .append_user_message_and_enqueue_pending(
                    session_id,
                    client_message_id,
                    message,
                    &image_paths,
                )
                .await?;

            if self
                .runtime_inputs
                .lock()
                .unwrap()
                .get(session_id)
                .is_none()
            {
                self.store.reset_in_flight_user_messages(session_id).await?;
                let resume_thread_id = snapshot
                    .session
                    .runtime_session_id
                    .clone()
                    .or_else(|| find_latest_codex_thread_id(&snapshot.events));

                if let Some(thread_id) = resume_thread_id {
                    if snapshot.session.runtime_session_id.as_deref() != Some(thread_id.as_str()) {
                        self.store
                            .update_runtime_session_id(session_id, &thread_id)
                            .await?;
                    }

                    self.spawn_attached_codex_runtime(
                        session_id,
                        &snapshot.session.workspace_path,
                        thread_id,
                    )
                    .await?;
                } else if snapshot.session.source_kind == "managed" {
                    self.spawn_codex_runtime(session_id, &snapshot.session.workspace_path)
                        .await?;
                }
            }

            self.drain_codex_pending_messages(session_id).await?;
            return Ok(event_id);
        }

        let event_id = self
            .store
            .append_user_message_event(session_id, client_message_id, &message, &image_paths)
            .await?;

        let Some(sender) = self.runtime_inputs.lock().unwrap().get(session_id).cloned() else {
            return Ok(event_id);
        };

        let payload = encode_runtime_input(&snapshot.session.agent_kind, &message);
        sender
            .send(payload)
            .map_err(|_| anyhow::anyhow!("managed runtime input channel closed"))?;

        Ok(event_id)
    }

    async fn drain_codex_pending_messages(&self, session_id: &str) -> anyhow::Result<()> {
        let Some(sender) = self.runtime_inputs.lock().unwrap().get(session_id).cloned() else {
            return Ok(());
        };

        drain_one_codex_pending_message(
            self.store.clone(),
            self.codex_protocols.clone(),
            session_id,
            &sender,
        )
        .await
    }

    async fn spawn_claude_turn(
        &self,
        session_id: &str,
        message: String,
        runtime_session_id: Option<String>,
    ) -> anyhow::Result<()> {
        self.store
            .update_session_status(session_id, "running")
            .await?;
        self.store
            .append_event(
                session_id,
                "session.status.changed",
                r#"{"status":"running"}"#,
            )
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
        let runtime_children = self.runtime_children.clone();
        let child_handle = Arc::new(TokioMutex::new(Some(child)));
        runtime_children
            .lock()
            .unwrap()
            .insert(session_id.clone(), child_handle.clone());

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
                    Err(error) => {
                        let message = format!("Claude stream parse error: {error}");
                        let _ = store
                            .update_runtime_health(
                                &session_id,
                                "recoverable_error",
                                Some("protocol"),
                                Some(&message),
                            )
                            .await;
                        let _ = store
                            .append_event(
                                &session_id,
                                "session.error",
                                &serde_json::json!({
                                    "message": message,
                                    "line": truncate_for_event(&line),
                                    "willRetry": false
                                })
                                .to_string(),
                            )
                            .await;
                    }
                }
            }

            let mut child = child_handle.lock().await;
            if let Some(mut child) = child.take() {
                let _ = child.wait().await;
            }
            remove_runtime_child_if_current(&runtime_children, &session_id, &child_handle);
            let _ = store.update_session_status(&session_id, "suspended").await;
            let _ = store
                .append_event(
                    &session_id,
                    "session.status.changed",
                    r#"{"status":"suspended"}"#,
                )
                .await;
        });

        Ok(())
    }

    async fn spawn_codex_runtime(
        &self,
        session_id: &str,
        workspace_path: &str,
    ) -> anyhow::Result<()> {
        self.store
            .update_session_status(session_id, "running")
            .await?;
        self.store
            .append_event(
                session_id,
                "session.status.changed",
                r#"{"status":"running"}"#,
            )
            .await?;

        let protocol = CodexSessionProtocol::new(workspace_path.to_string());
        self.spawn_codex_runtime_with_protocol(session_id, protocol)
            .await
    }

    async fn spawn_attached_codex_runtime(
        &self,
        session_id: &str,
        workspace_path: &str,
        runtime_session_id: String,
    ) -> anyhow::Result<()> {
        self.store
            .update_session_status(session_id, "running")
            .await?;
        self.store
            .append_event(
                session_id,
                "session.status.changed",
                r#"{"status":"running"}"#,
            )
            .await?;

        let protocol =
            CodexSessionProtocol::new_attached(workspace_path.to_string(), runtime_session_id);
        self.spawn_codex_runtime_with_protocol(session_id, protocol)
            .await
    }

    async fn spawn_codex_runtime_with_protocol(
        &self,
        session_id: &str,
        mut protocol: CodexSessionProtocol,
    ) -> anyhow::Result<()> {
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
        let runtime_children = self.runtime_children.clone();
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let child_handle = Arc::new(TokioMutex::new(Some(child)));

        let bootstrap = protocol.bootstrap_requests();
        codex_protocols
            .lock()
            .unwrap()
            .insert(session_id.clone(), protocol);
        runtime_inputs
            .lock()
            .unwrap()
            .insert(session_id.clone(), tx.clone());
        runtime_children
            .lock()
            .unwrap()
            .insert(session_id.clone(), child_handle.clone());

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
                        if let Some(runtime_session_id) = result.runtime_session_id.as_deref() {
                            let _ = store
                                .update_runtime_session_id(&session_id, runtime_session_id)
                                .await;
                        }

                        if let Some(session_status) = result.session_status.as_deref() {
                            let _ = store
                                .update_session_status(&session_id, session_status)
                                .await;
                        }

                        if let Some(runtime_health) = result.runtime_health.as_deref() {
                            let runtime_error_kind = result
                                .runtime_error_kind
                                .as_ref()
                                .and_then(|kind| kind.as_deref());
                            let runtime_error_message = result
                                .runtime_error_message
                                .as_ref()
                                .and_then(|message| message.as_deref());
                            let _ = store
                                .update_runtime_health(
                                    &session_id,
                                    runtime_health,
                                    runtime_error_kind,
                                    runtime_error_message,
                                )
                                .await;
                        }

                        for request in result.outgoing {
                            let _ = tx.send(encode_json_line(request));
                        }
                        if let Some(event) = result.event {
                            let _ = store
                                .append_event(&session_id, &event.event_type, &event.payload_json)
                                .await;
                        }

                        if result.completed_user_message {
                            if let Ok(Some(message)) =
                                store.in_flight_user_message(&session_id).await
                            {
                                let _ = store
                                    .ack_in_flight_user_message(&session_id, message.id)
                                    .await;
                            }
                        }

                        if result.can_accept_user_message {
                            let _ = drain_one_codex_pending_message(
                                store.clone(),
                                codex_protocols.clone(),
                                &session_id,
                                &tx,
                            )
                            .await;
                        }
                    }
                    Err(error) => {
                        let message = format!("Codex protocol error: {error}");
                        let _ = store
                            .update_runtime_health(
                                &session_id,
                                "recoverable_error",
                                Some("protocol"),
                                Some(&message),
                            )
                            .await;
                        let _ = store
                            .append_event(
                                &session_id,
                                "session.error",
                                &serde_json::json!({
                                    "message": message,
                                    "line": truncate_for_event(&line),
                                    "willRetry": false
                                })
                                .to_string(),
                            )
                            .await;
                    }
                }
            }

            runtime_inputs.lock().unwrap().remove(&session_id);
            drop(tx);
            let _ = writer.await;
            let mut child = child_handle.lock().await;
            let exit_status = if let Some(mut child) = child.take() {
                child.wait().await.ok()
            } else {
                None
            };
            codex_protocols.lock().unwrap().remove(&session_id);
            remove_runtime_child_if_current(&runtime_children, &session_id, &child_handle);

            let in_flight_message = store
                .in_flight_user_message(&session_id)
                .await
                .ok()
                .flatten();
            if in_flight_message.is_some() {
                let _ = store.reset_in_flight_user_messages(&session_id).await;
            }

            let latest_status = store
                .load_snapshot(&session_id)
                .await
                .ok()
                .map(|snapshot| snapshot.session.status)
                .unwrap_or_else(|| "running".to_string());
            let shutdown_status = if latest_status == "failed" {
                "failed"
            } else {
                "suspended"
            };

            if let Some(message) = in_flight_message {
                let exit_summary = format_runtime_exit_summary(exit_status.as_ref());
                let error_message = format!(
                    "Codex runtime {exit_summary} before completing the current message; it will be retried."
                );
                let _ = store
                    .update_runtime_health(
                        &session_id,
                        "recoverable_error",
                        Some("runtime"),
                        Some(&error_message),
                    )
                    .await;
                let _ = store
                    .append_event(
                        &session_id,
                        "session.error",
                        &serde_json::json!({
                            "message": error_message,
                            "pendingMessageId": message.id,
                            "pendingMessageText": message.text,
                            "willRetry": true
                        })
                        .to_string(),
                    )
                    .await;
            } else {
                let _ = store
                    .update_runtime_health(&session_id, "offline", None, None)
                    .await;
            }
            let _ = store
                .update_session_status(&session_id, shutdown_status)
                .await;
            let _ = store
                .append_event(
                    &session_id,
                    "session.status.changed",
                    &serde_json::json!({ "status": shutdown_status }).to_string(),
                )
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

fn format_runtime_exit_summary(exit_status: Option<&ExitStatus>) -> String {
    match exit_status {
        Some(status) if status.success() => "exited".to_string(),
        Some(status) => format!("exited with status {status}"),
        None => "exited unexpectedly".to_string(),
    }
}

fn truncate_for_event(value: &str) -> String {
    const MAX_CHARS: usize = 500;
    let mut truncated = value.chars().take(MAX_CHARS).collect::<String>();
    if value.chars().count() > MAX_CHARS {
        truncated.push_str("...");
    }
    truncated
}

fn remove_runtime_child_if_current(
    runtime_children: &Arc<Mutex<HashMap<String, RuntimeChild>>>,
    session_id: &str,
    child_handle: &RuntimeChild,
) {
    let mut children = runtime_children.lock().unwrap();
    if children
        .get(session_id)
        .is_some_and(|current| Arc::ptr_eq(current, child_handle))
    {
        children.remove(session_id);
    }
}

async fn drain_one_codex_pending_message(
    store: Arc<SqliteSessionStore>,
    codex_protocols: Arc<Mutex<HashMap<String, CodexSessionProtocol>>>,
    session_id: &str,
    sender: &mpsc::UnboundedSender<String>,
) -> anyhow::Result<()> {
    if store.in_flight_user_message(session_id).await?.is_some() {
        return Ok(());
    }

    let can_accept_user_message = {
        let protocols = codex_protocols.lock().unwrap();
        protocols
            .get(session_id)
            .is_some_and(CodexSessionProtocol::can_accept_user_message)
    };
    if !can_accept_user_message {
        return Ok(());
    }

    let Some(pending_message) = store.claim_next_pending_user_message(session_id).await? else {
        return Ok(());
    };

    let outgoing = {
        let mut protocols = codex_protocols.lock().unwrap();
        protocols.get_mut(session_id).and_then(|protocol| {
            if !protocol.can_accept_user_message() {
                return None;
            }
            protocol
                .enqueue_user_message(UserMessage {
                    text: pending_message.text,
                    image_paths: pending_message.image_paths,
                })
                .ok()
        })
    };

    let Some(outgoing) = outgoing else {
        store.reset_in_flight_user_messages(session_id).await?;
        return Ok(());
    };

    for request in outgoing {
        sender
            .send(encode_json_line(request))
            .map_err(|_| anyhow::anyhow!("managed runtime input channel closed"))?;
    }

    Ok(())
}

fn format_message_for_claude(message: String, image_paths: &[String]) -> String {
    if image_paths.is_empty() {
        return message;
    }

    let paths = image_paths
        .iter()
        .map(|path| format!("- {path}"))
        .collect::<Vec<_>>()
        .join("\n");

    format!(
        "{message}\n\nAnalyze these images for this turn:\n{paths}\n\nUse these local image paths as visual context for the request."
    )
}

fn sanitize_attachment_filename(filename: &str) -> String {
    let leaf = filename
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or("attachment.png");
    let sanitized = leaf
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_') {
                character
            } else {
                '_'
            }
        })
        .collect::<String>();

    if sanitized.trim_matches('_').is_empty() {
        "attachment.png".into()
    } else {
        sanitized
    }
}

fn find_latest_codex_thread_id(events: &[StoredEvent]) -> Option<String> {
    events.iter().rev().find_map(|event| {
        let payload: serde_json::Value = serde_json::from_str(&event.payload_json).ok()?;
        payload
            .get("threadId")
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned)
    })
}

fn encode_json_line(value: serde_json::Value) -> String {
    value.to_string() + "\n"
}
