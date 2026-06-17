use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::Child,
    sync::{mpsc, Mutex as TokioMutex},
};

use crate::{
    adapters::{
        claude::{parse_claude_result_session_id, parse_claude_stream_line},
        codex_protocol::{CodexSessionProtocol, UserMessage},
        process::{claude_turn_launch, codex_managed_launch, spawn_command, LaunchCommand},
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
        self.store.load_snapshot_window(session_id, limit, before).await
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

    pub async fn events_after(&self, session_id: &str, cursor: i64) -> anyhow::Result<Vec<StoredEvent>> {
        self.store.events_after(session_id, cursor).await
    }

    pub async fn resume_session(&self, session_id: &str) -> anyhow::Result<SessionSnapshot> {
        let snapshot = self.store.load_snapshot(session_id).await?;

        if snapshot.session.agent_kind == "codex"
            && self.runtime_inputs.lock().unwrap().get(session_id).is_none()
        {
            let resume_thread_id = snapshot
                .session
                .runtime_session_id
                .clone()
                .or_else(|| find_latest_codex_thread_id(&snapshot.events));

            if let Some(thread_id) = resume_thread_id {
                if snapshot.session.runtime_session_id.as_deref() != Some(thread_id.as_str()) {
                    self.store.update_runtime_session_id(session_id, &thread_id).await?;
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

        self.store.load_snapshot(session_id).await
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

    pub async fn send_user_message(&self, session_id: &str, message: String) -> anyhow::Result<()> {
        self.send_user_message_with_images(session_id, message, Vec::new()).await
    }

    pub async fn send_user_message_with_images(
        &self,
        session_id: &str,
        message: String,
        image_paths: Vec<String>,
    ) -> anyhow::Result<()> {
        let snapshot = self.store.load_snapshot(session_id).await?;
        self.store
            .append_event(
                session_id,
                "user.message",
                &serde_json::json!({ "text": message, "imagePaths": image_paths }).to_string(),
            )
            .await?;

        if snapshot.session.agent_kind == "claude" {
            let message = format_message_for_claude(message, &image_paths);
            self.spawn_claude_turn(
                session_id,
                message,
                snapshot.session.runtime_session_id.clone(),
            )
            .await?;
            return Ok(());
        }

        if snapshot.session.agent_kind == "codex"
            && self.runtime_inputs.lock().unwrap().get(session_id).is_none()
        {
            let resume_thread_id = snapshot
                .session
                .runtime_session_id
                .clone()
                .or_else(|| find_latest_codex_thread_id(&snapshot.events));

            if let Some(thread_id) = resume_thread_id {
                if snapshot.session.runtime_session_id.as_deref() != Some(thread_id.as_str()) {
                    self.store.update_runtime_session_id(session_id, &thread_id).await?;
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

        let Some(sender) = self.runtime_inputs.lock().unwrap().get(session_id).cloned() else {
            return Ok(());
        };

        if snapshot.session.agent_kind == "codex" {
            let outgoing = {
                let mut protocols = self.codex_protocols.lock().unwrap();
                let Some(protocol) = protocols.get_mut(session_id) else {
                    return Ok(());
                };
                protocol.enqueue_user_message(UserMessage { text: message, image_paths })?
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
                    Err(_) => {}
                }
            }

            let mut child = child_handle.lock().await;
            if let Some(mut child) = child.take() {
                let _ = child.wait().await;
            }
            remove_runtime_child_if_current(&runtime_children, &session_id, &child_handle);
            let _ = store.update_session_status(&session_id, "suspended").await;
            let _ = store
                .append_event(&session_id, "session.status.changed", r#"{"status":"suspended"}"#)
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

        let protocol = CodexSessionProtocol::new(workspace_path.to_string());
        self.spawn_codex_runtime_with_protocol(session_id, protocol).await
    }

    async fn spawn_attached_codex_runtime(
        &self,
        session_id: &str,
        workspace_path: &str,
        runtime_session_id: String,
    ) -> anyhow::Result<()> {
        self.store.update_session_status(session_id, "running").await?;
        self.store
            .append_event(session_id, "session.status.changed", r#"{"status":"running"}"#)
            .await?;

        let protocol = CodexSessionProtocol::new_attached(workspace_path.to_string(), runtime_session_id);
        self.spawn_codex_runtime_with_protocol(session_id, protocol).await
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

            drop(tx);
            let _ = writer.await;
            let mut child = child_handle.lock().await;
            if let Some(mut child) = child.take() {
                let _ = child.wait().await;
            }
            runtime_inputs.lock().unwrap().remove(&session_id);
            codex_protocols.lock().unwrap().remove(&session_id);
            remove_runtime_child_if_current(&runtime_children, &session_id, &child_handle);
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
